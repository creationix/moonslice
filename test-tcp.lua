local await = require('continuable').fiber.await
local createFiber = require('continuable').fiber.new
local tcp = require('continuable').tcp

local server = tcp.new()

tcp.bind(server, "127.0.0.1", 8080)
tcp.listen(server, function ()
  local client = tcp.new()
  tcp.accept(server, client)

  local client = tcp.Stream:new(client)

  createFiber(function ()
    repeat
      local chunk = await(client:read())
      await(client:write(chunk))
    until not chunk
  end)()

end)


