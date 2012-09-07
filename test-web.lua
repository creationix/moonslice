local createServer = require('continuable').tcp.createServer
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
app = require('web-static')(app, {
  root = __dirname .. "/public",
  index = "index.html",
  autoIndex = true
})
app = require('web-log')(app)
app = require('web-autoheaders')(app)

-- Serve the HTTP web app on a TCP server
createServer("0.0.0.0", 8080, web.socketHandler(app))
