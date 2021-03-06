require 'laia.ClassWithOptions'
require 'laia.SignalHandler'
require 'warp_ctc'
local xlua = wrequire 'xlua'

local CTCTrainer, Parent = torch.class('laia.CTCTrainer',
				       'laia.ClassWithOptions')

-- Basic usage example:
-- trainer = CTCTrainer(model, train_batcher, valid_batcher, optim.rmsprop)
-- trainer:start()
-- while true do
--   train_epoch_info = trainer:trainEpoch(rmsprop_opts)
--   valid_epoch_info = trainer:validEpoch()
--   print(train_epoch_info.loss, valid_epoch_info.loss)
-- end

local function check_nan(x, m)
  return x:ne(x):sum()
end

local function check_inf(x, m)
  return x:ge(math.huge):sum() + x:le(-math.huge):sum()
end

function CTCTrainer:__init(model, train_batcher, valid_batcher, optimizer)
  Parent.__init(self, {
    batch_size = 16,
    use_distortions = false,
    use_distortions_after = 0,
    cer_trim = 0,
    snapshot_interval = 0,
    display_progress_bar = false,
    num_samples_epoch = 0,
    grad_clip = 0,
    check_nan = false,
    check_inf = false,
    normalize_loss = true,
    shuffle_valid = false,
    batchChunkSize = 0,
  })
  self._model = model
  self._train_batcher = train_batcher
  self._valid_batcher = valid_batcher
  self._optimizer = optimizer
  -- Use :start() to initialize the trainer
  self._initialized = false
end

function CTCTrainer:setModel(model)
  self._model = model
  self._initialized = false
  return self
end

function CTCTrainer:setTrainBatcher(batcher)
  self._train_batcher = batcher
  self._initialized = false
  return self
end

function CTCTrainer:setValidBatcher(batcher)
  self._valid_batcher = batcher
  self._initialized = false
  return self
end

function CTCTrainer:setOptimizer(optimizer)
  self._optimizer = optimizer
  self._initialized = false
  return self
end

function CTCTrainer:setDistorter(distorter)
  self._distorter = distorter
  self._initialized = false
  if self._distorter and self._opt.use_distortions then
    laia.log.info('CTCTrainer uses the distorter:\n' ..
		    self._distorter:__tostring__())
  end
  return self
end

function CTCTrainer:setAdversarialRegularizer(regularizer)
  self._adversarial_regularizer = regularizer
  self._initialized = false
  if self._adversarial_regularizer then
    laia.log.info('CTCTrainer uses the adversarial regularizer:\n' ..
		    self._adversarial_regularizer:__tostring__())
  end
  return self
end

function CTCTrainer:setWeightRegularizer(regularizer)
  self._weight_regularizer = regularizer
  self._initialized = false
  if self._weight_regularizer then
    laia.log.info('CTCTrainer uses the weight regularizer:\n' ..
		    self._weight_regularizer:__tostring__())
  end
  return self
end

function CTCTrainer:registerOptions(parser, advanced)
  advanced = advanced or false
  parser:option(
    '--batch_size -b', 'Batch size', self._opt.batch_size, laia.toint)
    :gt(0)
    :bind(self._opt, 'batch_size')
    :advanced(advanced)
  parser:option(
    '--use_distortions',
    'If true, augment the training set using random distortions.',
    self._opt.use_distortions, laia.toboolean)
    :bind(self._opt, 'use_distortions')
    :advanced(advanced)
  parser:option(
    '--use_distortions_after',
    'Start using distortions after this epoch (set this value to 0 to use ' ..
    'distortions from the beginning).',
    self._opt.use_distortions_after, laia.toint)
    :bind(self._opt, 'use_distortions_after')
    :gt(0)
    :advanced(advanced)
  parser:option(
    '--cer_trim', 'For computing CER, removes leading, trailing and ' ..
      'repetitions of given symbol number (i.e. space).',
    self._opt.cer_trim, laia.toint)
    :argname('<sym>')
    :ge(0)
    :bind(self._opt, 'cer_trim')
    :advanced(advanced)
  --[[
  parser:option(
    '--snapshot_interval',
    'If n>0, create a snapshot of the model every n batches.',
    self._opt.snapshot_interval, laia.toint)
    :argname('<n>')
    :ge(0)
    :bind(self._opt, 'snapshot_interval')
    :advanced(advanced)
  --]]
  parser:option(
    '--grad_clip', 'If c>0, clip gradients to the range [-c,+c].',
    self._opt.grad_clip, tonumber)
    :argname('<c>')
    :ge(0)
    :bind(self._opt, 'grad_clip')
    :advanced(advanced)
  parser:option(
    '--display_progress_bar',
    'Display a progress bar on the terminal showing the status ' ..
    'of the training and validation epoch. Note: if you ' ..
      'redirect the output to a file, the progress bar is not ' ..
      'displayed.', self._opt.display_progress_bar, laia.toboolean)
    :bind(self._opt, 'display_progress_bar')
    :advanced(advanced)
  parser:option(
    '--num_samples_epoch',
    'Number of training samples to process in each epoch; ' ..
      'If n=0, this value is equal to the number of samples in the training '..
      'partition.', self._opt.num_samples_epoch, laia.toint)
    :argname('<n>')
    :ge(0)
    :bind(self._opt, 'num_samples_epoch')
    :advanced(advanced)
  parser:option(
    '--check_nan', 'If true, check for NaN values during training.',
    self._opt.check_nan, laia.toboolean)
    :bind(self._opt, 'check_nan')
    :advanced(advanced)
  parser:option(
    '--check_inf', 'If true, check for infinity values during training.',
    self._opt.check_inf, laia.toboolean)
    :bind(self._opt, 'check_inf')
    :advanced(advanced)
  parser:option(
    '--normalize_loss', 'If true, normalize the loss among the batch size and the length of the samples.',
    self._opt.normalize_loss, laia.toboolean)
    :bind(self._opt, 'normalize_loss')
    :advanced(advanced)
  parser:option(
    '--shuffle_valid', 'If true, shuffle the validation data on each epoch.',
    self._opt.shuffle_valid, laia.toboolean)
    :bind(self._opt, 'shuffle_valid')
    :advanced(advanced)
  parser:option(
    '--batch_chunk_size', 'If >0, split the batch in chunks of this size (in' ..
    ' MB). Useful to perform constant batch size updates with scarce memory.',
    self._opt.batchChunkSize, laia.toint)
    :bind(self._opt, 'batchChunkSize')
    :advanced(advanced)
end

function CTCTrainer:checkOptions()
  assert(self._opt.batch_size > 0 and laia.isint(self._opt.batch_size),
	 ('Batch size must be positive integer (value = %s)'):format(
	   self._opt.batch_size))
  assert(laia.isint(self._opt.cer_trim),
	 ('CER trim symbol must be an integer (value = %s)'):format(
	   self._opt.cer_trim))
  assert(laia.isint(self._opt.snapshot_interval),
	 ('Snapshot interval must be an integer (value = %s)'):format(
	   self._opt.snapshot_interval))
  assert(type(self._opt.grad_clip) == 'number',
	 ('Gradient clip value must be a number (value = %s)'):format(
	   self._opt.grad_clip))
  assert(type(self._opt.display_progress_bar) == 'boolean',
	 ('Display progress bar must be a boolean (value = %s)'):format(
	   self._opt.display_progress_bar))
  assert(type(self._opt.check_nan) == 'boolean',
	 ('Expected a boolean value (got value = %s)')
	   :format(self._opt.check_nan))
  assert(type(self._opt.check_inf) == 'boolean',
	 ('Expected a boolean value (got value = %s)')
	   :format(self._opt.check_inf))
  -- Log some warnings
  if self._opt.display_progress_bar and not xlua then
    laia.log.warn('Progress bar not displayed, xlua was not found')
  end
  if self._opt.display_progress_bar and not laia.stdout_isatty then
    laia.log.warn('Progress bar not displayed, stdout is redirected')
  end
end

function CTCTrainer:start()
  assert(self._model ~= nil)
  assert(self._train_batcher ~= nil and self._train_batcher:numSamples() > 0)
  assert(self._optimizer ~= nil)
  assert(self._distorter or not self._opt.use_distortions,
	 'No distorter passed to the CTCTrainer, but --use_distortions=true')
  assert(self._train_batcher:symCount()[0] == 0,
         'CTC non-character symbol found in transcripts')

  -- Flatten the model parameters into a single big chunk of memory.
  self._parameters, self._gradParameters = self._model:getParameters()
  -- Define some buffers that will be used for different batches to avoid
  -- multiple data allocation/dellocation.
  self._gradOutput = torch.Tensor():type(self._model:type())
  self._tr_batch_img = torch.Tensor():type(self._train_batcher:cacheType())
  self._va_batch_img =
    self._valid_batcher and torch.Tensor():type(self._valid_batcher:cacheType())
  -- Total number of precessed training and validation batches, used to update
  -- the monitor snapshot only at certain times.
  self._num_processed_train_batches = 0
  self._num_processed_valid_batches = 0
  -- Compute the number of training samples to process in each epoch.
  -- Note: This number may be different from the total number of training
  -- samples, or the value of --num_samples_epoch, because of the batch_size.
  if self._opt.num_samples_epoch > 0 then
    self._train_num_samples = self._opt.batch_size *
      math.ceil(self._opt.num_samples_epoch / self._opt.batch_size)
  else
    self._train_num_samples = self._opt.batch_size *
      math.ceil(self._train_batcher:numSamples() / self._opt.batch_size)
  end

  -- Compute the number of validation samples to process in each epoch.
  -- See Note before.
  self._valid_num_samples = self._valid_batcher and (self._opt.batch_size *
    math.ceil(self._valid_batcher:numSamples() / self._opt.batch_size))

  self._currEpoch = 0
  self._initialized = true
end

function CTCTrainer:trainEpoch(optimizer_params, batcher_reset_params)
  assert(self._initialized, 'CTCTrainer must be initialized with :start()')
  self._currEpoch = self._currEpoch + 1
  -- Reset batcher with the given parameters
  self._train_batcher:epochReset(batcher_reset_params)
  -- Useful information for monitoring the performance on trainining data
  local epoch_info = {
    loss        = 0,
    num_frames  = 0,
    posteriors  = {},
    num_ins_ops = {},
    num_del_ops = {},
    num_sub_ops = {},
    hyp_trim    = {},
    ref_trim    = {},
    time_start  = os.time(),
    time_end    = nil,
    numChunks   = {},
    numChunkSamples = {},
  }
  for b=1,self._train_num_samples,self._opt.batch_size do
    -- If exit signal was captured, terminate
    if laia.SignalHandler.ExitRequested() then return nil end
    -- Load batch from batcher
    local batch_img, batch_gt, batch_sizes = self._train_batcher:next(
      self._opt.batch_size, self._tr_batch_img)
    -- Ensure that batch is in the same device (GPU vs CPU) as the model
    batch_img = batch_img:type(self._model:type())
    -- Apply distortions, if a distorter was given
    if self._distorter and self._opt.use_distortions and
       self._currEpoch > self._opt.use_distortions_after then
      if b == 1 then
	laia.log.debug('Applying distortions on the training data (this ' ..
		       'message only shown for the first batch on each epoch).')
      end
      batch_img = self._distorter:distort(batch_img)
    end
    -- Run optimizer on the batch
    self._optimizer(
      function(_)
	local batch_costs = self:_trainBatch(batch_img, batch_gt)
	CTCTrainer._updateCosts(epoch_info, batch_costs)
	return batch_costs.loss, self._gradParameters
      end, self._parameters, optimizer_params)
    -- Show progress bar only if running on a tty
    if xlua and laia.stdout_isatty and self._opt.display_progress_bar then
      xlua.progress(b + self._opt.batch_size - 1, self._train_num_samples)
    end
    -- Update number of processed batches
    self._num_processed_train_batches = self._num_processed_train_batches + 1
  end
  epoch_info.time_end = os.time()
  return epoch_info
end

function CTCTrainer:validEpoch(batcher_reset_params)
  assert(self._initialized, 'CTCTrainer must be initialized with :start()')
  -- Reset batcher with the given parameters
  self._valid_batcher:epochReset(batcher_reset_params)
  -- Useful information for monitoring the performance on validation data
  local epoch_info = {
    loss        = 0,
    num_frames  = 0,
    posteriors  = {},
    num_ins_ops = {},
    num_del_ops = {},
    num_sub_ops = {},
    hyp_trim    = {},
    ref_trim    = {},
    time_start  = os.time(),
    time_end    = nil,
    numChunks   = {},
    numChunkSamples = {},
  }
  for b=1,self._valid_num_samples,self._opt.batch_size do
    -- If exit signal was captured, terminate
    if laia.SignalHandler.ExitRequested() then return nil end
    -- Load batch from batcher
    local batch_img, batch_gt, batch_sizes = self._valid_batcher:next(
      self._opt.batch_size, self._va_batch_img)
    -- Ensure that batch is in the same device as the model
    batch_img = batch_img:type(self._model:type())
    -- Forward pass
    local batch_costs = self:_fbPass(batch_img, batch_gt, false)
    CTCTrainer._updateCosts(epoch_info, batch_costs)
    -- Show progress bar only if running on a tty
    if xlua and laia.stdout_isatty and self._opt.display_progress_bar then
      xlua.progress(b + self._opt.batch_size - 1, self._valid_num_samples)
    end
    -- Update number of processed batches
    self._num_processed_valid_batches = self._num_processed_valid_batches + 1
  end
  epoch_info.time_end = os.time()
  return epoch_info
end

-- Perform forward/backward on a training batch, and apply the regularizers
-- to obtain the regularized loss function and the gradient of it w.r.t. the
-- model parameters.
-- Note: This updates self._gradParameters directly and returs the different
-- costs on the training batch for monitoring purposes. See the call to
-- optimizer() in trainEpoch() to see how this method is used.
function CTCTrainer:_trainBatch(batch_img, batch_gt)
  -- Regular backpropagation pass
  local batch_costs = self:_fbPass(batch_img, batch_gt, true)

  -- Adversarial samples regularization
  if self._adversarial_regularizer then
    batch_costs.loss = self._adversarial_regularizer:regularize(
      batch_costs.loss, self._model, batch_img,
      function(x) return self:_fbPass(x, batch_gt, true).loss end)
  end

  -- Weight decay regularization
  if self._weight_regularizer then
    batch_costs.loss = self._weight_regularizer:regularize(
      batch_costs.loss, self._model)
  end

  -- Clip gradients
  if self._opt.grad_clip > 0 then
    -- Number of clamped gradients, for debugging purposes
    local ncg = torch.abs(self._gradParameters):gt(self._opt.grad_clip):sum()
    if ncg > 0 then
      laia.log.debug(('%d [%.2f%%] gradients clamped to [-%g,%g]'):format(
	  ncg, 100 * ncg / self._gradParameters:nElement(),
	  self._opt.grad_clip, self._opt.grad_clip))
      self._gradParameters:clamp(-self._opt.grad_clip, self._opt.grad_clip)
    end
  end

  return batch_costs
end

-- Perform forward (and optionally, backprop) pass. This is common
-- code used for both training and evaluation of the model.
function CTCTrainer:_fbPass(batch_img, batch_gt, do_backprop)
  do_backprop = do_backprop or false
  local gradParamAcc = nil
  if do_backprop then
    self._model:training()
    -- TOOD(jpuigcerver): We should not need this copy, since model:backward()
    -- should accumulate the gradients unless model:zeroGradParameters() is
    -- called, however this does not seem to work properly.
    gradParamAcc = self._gradParameters:clone():zero()
  else
    self._model:evaluate()
  end
  self._model:clearState()
  local batchSize = batch_img:size(1)
  assert(batchSize == #batch_gt,
	 ('The number of transcripts is not equal to the number of images '..
          '(expected = %d, actual = %d)'):format(batchSize, #batch_gt))
  -- If the batch is too big to fill in memory, split the batch in chunks
  -- but perform a single model update (gradients are accumulated)
  local numChunks, numChunkSamples = 1, batchSize
  local batchSizeMB =
    batch_img:nElement() * batch_img:elementSize() / 1048576
  local sampleSizeMB =
    batch_img[1]:nElement() * batch_img:elementSize() / 1048576
  if not self.warnSampleSize and self._opt.batchChunkSize > 0 and
  sampleSizeMB > self._opt.batchChunkSize then
    laia.log.warn(
      ('Your maximum batch chunk size is smaller than the size ' ..
       'of one sample (%.2fMB vs. %.2fMB). If memory is scarce, Laia ' ..
       'might crash soon. This message won\'t be shown again.')
	:format(self._opt.batchChunkSize, sampleSizeMB))
    self.warnSampleSize = true
  end
  if self._opt.batchChunkSize > 0 then
    numChunks = math.min(math.ceil(batchSizeMB / self._opt.batchChunkSize), batchSize)
    numChunkSamples = math.ceil(batchSize / numChunks)
  end

  local numFrames = 0
  local batch_losses = {}
  local batch_dc_trim, batch_gt_trim = {}, {}
  local batch_num_ins_ops, batch_num_del_ops, batch_num_sub_ops = {}, {}, {}
  for chunkStart=1,batchSize,numChunkSamples do
    if chunkStart + numChunkSamples - 1 > batchSize then
      numChunkSamples = batchSize - chunkStart + 1
    end
    local chunkImg   = batch_img:narrow(1, chunkStart, numChunkSamples)
    local chunkGt    = table.subrange(batch_gt, chunkStart, chunkStart + numChunkSamples - 1)

    -- Forward pass
    self._model:forward(chunkImg)
    local output = self._model.output
    numFrames = numFrames + output:size(1)
    -- Check output size
    assert(self._train_batcher:numSymbols() == output:size(2),
	   ('Expected model output to have %d dimensions and got %d'):format(
	     self._train_batcher:numSymbols(), output:size(2)))
    -- Check NaNs
    if self._opt.check_nan then
      local n = check_nan(output)
      local p = n / output:nElement() * 100
      assert(n == 0, 'Found %d (%.2f%%) NaN values during forward!', n, p)
    end
    -- Check NaNs
    if self._opt.check_inf then
      local n = check_inf(output)
      local p = n / output:nElement() * 100
      assert(n == 0, 'Found %d (%.2f%%) inf values during forward!', n, p)
    end
    -- Set _gradOutput to have the same size as the output and fill it with zeros
    self._gradOutput = self._gradOutput:typeAs(output):resizeAs(output):zero()

    -- TODO(jpuigcerver): This assumes that all sequences have the same number
    -- of frames, which should not be the case, since padding should be ignored!
    local sizes = {}
    local seq_len = output:size(1) / chunkImg:size(1)
    for i=1,chunkImg:size(1) do table.insert(sizes, seq_len) end

    -- Compute loss function and gradients w.r.t. the output
    if self._model:type() == 'torch.CudaTensor' then
      local chunkLosses = gpu_ctc(output, self._gradOutput, chunkGt, sizes)
      table.extend(batch_losses, chunkLosses)
    elseif self._model:type() == 'torch.FloatTensor' then
      local chunkLosses = cpu_ctc(output, self._gradOutput, chunkGt, sizes)
      table.extend(batch_losses, chunkLosses)
    else
      laia.log.fatal(
	('CTC is not implemented for tensors of type %q'):format(output:type()))
    end
    -- Check NaNs
    if self._opt.check_nan then
      local n = check_nan(self._gradOutput)
      local p = n / self._gradOutput:nElement() * 100
      assert(n == 0, 'Found %d (%.2f%%) NaN values during CTC!', n, p)
    end
    -- Check NaNs
    if self._opt.check_inf then
      local n = check_inf(self._gradOutput)
      local p = n / self._gradOutput:nElement() * 100
      assert(n == 0, 'Found %d (%.2f%%) inf values during CTC!', n, p)
    end

    -- Compute gradients of the loss function w.r.t parameters
    if do_backprop then
      self._model:zeroGradParameters()
      self._model:backward(chunkImg, self._gradOutput)
      -- Check NaNs
      if self._opt.check_nan then
	local n = check_nan(self._gradParameters)
	local p = n / self._gradParameters:nElement() * 100
	assert(n == 0, 'Found %d (%.2f%%) NaN values during backward!', n, p)
      end
      -- Check NaNs
      if self._opt.check_inf then
	local n = check_inf(self._gradParameters)
	local p = n / self._gradParameters:nElement() * 100
	assert(n == 0, 'Found %d (%.2f%%) inf values during backward!', n, p)
      end
      gradParamAcc:add(self._gradParameters)
    end

    -- Perform framewise decoding to estimate CER
    local chunkDecode = laia.framewise_decode(chunkImg:size(1), output)
    for i=1,#chunkDecode do
      local dc_i = chunkDecode[i]
      local gt_i = chunkGt[i]
      if self._opt.cer_trim > 0 then
	dc_i = laia.symbol_trim(dc_i, self._opt.cer_trim)
	gt_i = laia.symbol_trim(gt_i, self._opt.cer_trim)
      end
      local _, edit_ops = laia.levenshtein(gt_i, dc_i)
      table.insert(batch_num_ins_ops, edit_ops.ins)
      table.insert(batch_num_del_ops, edit_ops.del)
      table.insert(batch_num_sub_ops, edit_ops.sub)
      table.insert(batch_dc_trim, dc_i)
      table.insert(batch_gt_trim, gt_i)
    end
  end

  if do_backprop then
    -- Copy accumulated gradients back to
    self._gradParameters:copy(gradParamAcc)
    -- Make gradients independent of the batch size and sequence length
    if self._opt.normalize_loss then
      self._gradParameters:div(numFrames)
    end
  end

  -- Return, for each sample in the batch, the total loss (including
  -- regularization terms, adversarial, etc), the posterior probability
  -- of the reference sequence, number of edit operations of each type, the
  -- decoded (hypothesis) sequence and the reference sequence (after triming).
  return {
    -- Sum individual batch losses
    loss        = table.reduce(batch_losses, operator.add, 0),
    -- Batch Size x Length of samples
    num_frames  = numFrames,
    -- Convert losses to (log-)posteriors, i.e loss = -log p(y|x), per sample!
    posteriors  = table.map(batch_losses, function(x) return -x end),
    -- Number of insertion operations (after trimming), for each sample!
    num_ins_ops = batch_num_ins_ops,
    -- Number of deletion operations (after trimming), for each sample!
    num_del_ops = batch_num_del_ops,
    -- Number of subtitution operations (after trimming), for each sample!
    num_sub_ops = batch_num_sub_ops,
    -- Hypothesis transcript (after trimming), for each sample!
    hyp_trim    = batch_dc_trim,
    -- Reference transcript (after trimming), for each sample!
    ref_trim    = batch_gt_trim,
    --
    --
    -- These are not costs, but are useful information to monitor.
    -- Number of chunks in which the batch was divided
    numChunks   = {numChunks},
    numChunkSamples = {numChunkSamples},
  }
end

-- Usage:
-- a = { loss = 5, posteriors = {-0.2} }
-- b = { loss = 2, posteriors = {-0.01, -1.1} }
-- CTCTrainer._updateCosts(a, b)
-- print(a)
-- { loss = 7, posteriors = {-0.2, -0.01, -1.1} }
function CTCTrainer._updateCosts(dst, src)
  for k,v in pairs(src) do
    if type(v) == 'number' then
      assert(type(dst[k]) == 'number')
      dst[k] = dst[k] + v
    elseif type(v) == 'table' then
      assert(type(dst[k]) == 'table')
      table.foreach(v, function(i, x) table.insert(dst[k], x) end)
    end
  end
end

-- Usage:
-- a = { loss = 5, posteriors = {-0.2, -0.5} }
-- CTCTrainer._resetCosts(a)
-- print(a)
-- { loss = 0, posteriors = { } }
function CTCTrainer._resetCosts(dst)
  for k,v in pairs(dst) do
    if type(v) == 'number' then
      dst[k] = 0
    elseif type(v) == 'table' then
      dst[k] = {}
    end
  end
end

return CTCTrainer
