local TripletCriterion, parent = torch.class('nn.TripletCriterion', 'nn.Criterion')

function TripletCriterion:__init(samples, blocks, norm, margin)
   parent.__init(self)

   self.norm = norm or 2
   self.alpha = margin or 0.2
   self.samples = samples or 1     -- use all anchor-positive pairs for (>1)
   self.blocks = blocks or 0
   if self.samples > 1 then
      assert(self.blocks ~= 0)
   end

   self.dist = torch.Tensor()
   self.embeddings = torch.Tensor()
   self.loss = torch.Tensor()
end

function TripletCriterion:updateOutput(input, target)
   assert(input:dim() == 2, 'input should have 2 dimensions of (batch x embedding)')
   assert(input:size(1) >= self.samples*self.blocks)

   if input:type() == 'torch.CudaTensor' then
      -- kernel call
      input.nn.TripletCriterion_updateOutput(self, input, target)
   else
      local nb_batch = input:size(1)
      local length = input:size(2)
      local nb_blocks = math.floor(nb_batch/self.samples)

      -- calculate distance matrix
      self.dist:resize(nb_batch, nb_batch)
      for i = 1, nb_batch do
         for j = i, nb_batch do
            if j == i then
               self.dist[i][j] = 0
            else
               self.dist[i][j] = torch.dist(input[i], input[j], self.norm)
               self.dist[j][i] = self.dist[i][j]
            end
         end
      end

      -- find pos/neg embeddings indices
      -- (i) hard anchor-positive pair
      if self.samples == 1 then
         self.embeddings:resize(nb_batch, 3)
         for i = 1, nb_batch do
            local ipos = i
            local vpos = 0
            local ineg = i
            local vneg = math.huge
            for j = 1, nb_batch do
               if (target[j] == target[i]) and (vpos < self.dist[i][j]) then
                  ipos = j
                  vpos = self.dist[i][j]
               end
            end
            for j = 1, nb_batch do
               if (target[j] ~= target[i]) and
                  (vpos < self.dist[i][j]) and
                  (vneg > self.dist[i][j]) then
                  ineg = j
                  vneg = self.dist[i][j]
               end
            end
            self.embeddings[i][1] = i
            self.embeddings[i][2] = ipos
            self.embeddings[i][3] = ineg
         end

      -- (ii) all anchor-positive pairs
      elseif self.samples > 1 then
         -- calculate nb of all pairs
         self.embeddings:resize(nb_batch*(self.samples-1), 3):zero()

         -- repeat batch (samples-1) times
         for i = 0, self.samples-2 do
            for j = 0, nb_blocks-1 do
               for k = 0, self.samples-1 do

                  -- pick an element in distance matrix
                  local row = j*self.samples + k + 1
                  local col = j*self.samples + i + 1
                  col = ((row > col) and col) or (col + 1)

                  -- find positive embedding
                  local ipos = col
                  local vpos = self.dist[row][col]

                  -- find negative embedding
                  local ineg = row
                  local vneg = math.huge
                  for l = self.samples*self.blocks+1, nb_batch do
                     if (target[l] ~= target[row]) and
                        (vpos < self.dist[row][l]) and
                        (vneg > self.dist[row][l]) then
                        ineg = l
                        vneg = self.dist[row][l]
                     end
                  end
                  self.embeddings[i*nb_batch + j*self.samples + k + 1][1] = row
                  self.embeddings[i*nb_batch + j*self.samples + k + 1][2] = ipos
                  self.embeddings[i*nb_batch + j*self.samples + k + 1][3] = ineg
               end
            end
         end
      end

      -- compute loss
      self.loss:resize(self.embeddings:size(1))
      for i = 1, self.embeddings:size(1) do
         -- do not penalize if negative is not found
         if self.embeddings[i][1] == self.embeddings[i][3] then
            self.loss[i] = 0
         else
            local d_ap = torch.dist(input[self.embeddings[i][1]], input[self.embeddings[i][2]], 2)
            local d_an = torch.dist(input[self.embeddings[i][1]], input[self.embeddings[i][3]], 2)
            self.loss[i] = math.max(0, d_ap*d_ap + self.alpha - d_an*d_an)
         end
      end
   end

   if self.samples > 1 then
      self.output = self.loss:sum()/(self.blocks*self.samples*(self.samples-1))
   else
      self.output = self.loss:sum()/input:size(1)
   end

   return self.output
end

function TripletCriterion:updateGradInput(input, target)
   self:updateOutput(input, target)

   if input:type() == 'torch.CudaTensor' then
      input.nn.TripletCriterion_updateGradInput(self, input, target)
   else
      local nb_pairs = self.loss:size(1)
      local length = input:size(2)
      self.gradInput:resize(nb_pairs, length)
      for i = 1, nb_pairs do
         if self.loss[i] > 0 then
            self.gradInput[i] = (input[self.embeddings[i][3]] - input[self.embeddings[i][2]])*2/nb_pairs
         else
            self.gradInput[i] = 0
         end
      end
   end

   return self.gradInput
end
