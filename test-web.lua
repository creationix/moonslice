local createServer = require('continuable').tcp.createServer
local createFiber = require('continuable').fiber.new
local await = require('continuable').fiber.await
local web = require('web')

-- Write a simple web app
local app = function (req, res)
  if req.url.path == "/greet" then
    return res(200, {
      ["Content-Type"] = "text/plain",
      ["Content-Length"] = 12
    }, "Hello World\n")
  end
  res(404, {
    ["Content-Type"] = "text/plain",
    ["Content-Length"] = 10
  }, "Not Found\n")
end

-- Wrap it in some useful middleware modules
app = web.static(app, {
  root = __dirname .. "/public",
  index = "index.html",
  autoIndex = true
})
app = web.log(app)
app = web.cleanup(app)

-- Serve the HTTP web app on a TCP server
createServer("127.0.0.1", 8080, web.socketHandler(app))
