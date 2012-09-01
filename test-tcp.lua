local createServer = require('continuable').tcp.createServer
local createFiber = require('continuable').fiber.new
local await = require('continuable').fiber.await

createServer("127.0.0.1", 8080, function (client)
  createFiber(function ()
    repeat
      local chunk = await(client:read())
      p{chunk=chunk}
      await(client:write(chunk))
    until not chunk
  end)()
end)
