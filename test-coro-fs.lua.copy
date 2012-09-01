local await = require('continuable').fiber.await
local createFiber = require('continuable').fiber.new

local fs = require('continuable').fs

-- Copy a file from one
local function copy(inputPath, outputPath)
  local input = fs.ReadStream:new(await(fs.open(inputPath, "r")))
  local output = fs.WriteStream:new(await(fs.open(outputPath, "w")))
  repeat
    local chunk = await(input:read())
    p("chunk", chunk)
    await(output:write(chunk))
  until not chunk
  return input.offset
end

createFiber(function ()
  print("Copying file")
  local bytes = copy(__filename, __filename .. ".copy")
  print("copied " .. bytes .. " bytes")
end)()
