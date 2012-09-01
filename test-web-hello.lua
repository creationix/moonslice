local createServer = require('continuable').tcp.createServer
local web = require('web')

-- Write a simple web app
local app = function (req, res)
  return res(200, {
    ["Content-Type"] = "text/plain",
    ["Content-Length"] = 12
  }, "Hello World\n")
end

app = web.cleanup(app)

-- Serve the HTTP web app on a TCP server
createServer("127.0.0.1", 8080, web.socketHandler(app))
