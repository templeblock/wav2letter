local DecoderCriterion = torch.class('nn.DecoderCriterion', 'nn.Criterion')
local argcheck = require 'argcheck'

DecoderCriterion.__init = argcheck{
   noordered = true,
   {name="self", type="nn.DecoderCriterion"},
   {name="decoder", type="table"},
   {name="dopt", type="table"},
   {name="N", type="number"},
   {name="scale", type="function", default=function(input, target) return 1 end},
   call =
      function(self, decoder, dopt, N, scale)
         assert(N == #decoder.letters+1)
         self.decoder = decoder
         self.dopt = dopt
         local function falscale(input, target)
            self.__scale = scale(input, target)
            return -self.__scale
         end
         local function fccscale()
            return self.__scale
         end
         self.fal = nn.ForceAlignCriterion(N, true, falscale)
         self.fcc = nn.FullConnectCriterionC(N, false, fccscale)
         self.fcc.transitions = self.fal.transitions
         self.transitions = self.fal.transitions
         self.gtransitions = self.fal.gtransitions
         self.gradInput = self.fal.gradInput
      end
}

function DecoderCriterion:setWordTarget(words)
   self.__words = words
end

function DecoderCriterion:updateOutput(input, target)
   -- fal first because of scale(input, target)
   -- viterbi to get the path as hint
   local faloutput = self.fal:updateOutput(input, target)
   local scale = self.__scale

   -- we need to add the lm score note: substracting lm score from the
   -- decoder is wrong (decoder finds best path with lm score... so fal
   -- might be higher if lm score is removed there)
   local lmoutput = self.dopt.lmweight*self.decoder.lm:estimate(self.decoder.usridx2lmidx(self.__words))
   lmoutput = lmoutput + self.dopt.wordscore*self.__words:size(1)
   lmoutput = lmoutput*(-scale)

   -- we do not clone path (fast but ugly)
   local decoutputs
   self.__predictions, self.__lpredictions, decoutputs
      = self.decoder(self.dopt, self.transitions, input)

   local decoutput = scale*decoutputs

   self.output = (faloutput + lmoutput) + decoutput

   -- skip if score is negative (could also use the hint...)
   if self.output <= 0 then
      self.__fallback = true
      self.output = faloutput + self.fcc:updateOutput(input)
   else
      self.__fallback = false
   end

   return self.output
end

function DecoderCriterion:decodedstring()
   return self.decoder.tensor2string(self.__predictions)
end

function DecoderCriterion:zeroGradParameters()
   self.fal:zeroGradParameters()
   self.fcc:zeroGradParameters()
end

function DecoderCriterion:updateGradInput(input, target)
   -- skip if score is negative
   if self.__fallback then
      self.fal:updateGradInput(input, target)
      self.fcc:updateGradInput(input)
      self.gradInput:add(self.fcc.gradInput)
      self.gtransitions:add(self.fcc.gtransitions)
      return self.gradInput
   end

   self.fal:updateGradInput(input, target)

   local ginput = self.gradInput
   local scale = self.__scale
   local target = self.__lpredictions
   local gtransitions = self.gtransitions
   local idxm1
   local N = target:size(1)-2 -- beware of start/end nodes
   for t=1,N do
      -- beware of start/end nodes -- beware of 0 indexing
      local idx = target[t+1]+1
      ginput[t][idx] = ginput[t][idx] + scale
      if idxm1 then
         gtransitions[idx][idxm1] = gtransitions[idx][idxm1] + scale
      end
      idxm1 = idx
   end
   return self.gradInput
end

function DecoderCriterion:updateParameters(lr)
   self.fal:updateParameters(lr)
end

function DecoderCriterion:parameters()
   return {self.transitions}, {self.gtransitions}
end

function DecoderCriterion:share(layer, ...)
   local arg = {...}
   for i,v in ipairs(arg) do
      if self[v] ~= nil then
         self[v]:set(layer[v])
      end
   end
   return self
end