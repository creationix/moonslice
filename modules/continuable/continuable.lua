local native = require('uv_native')
local Object = require('core').Object

local function noop() end
local uv = {}

local Queue = Object:extend()
uv.Queue = Queue

function Queue:initialize()
  self.first = 1
  self.last = 0
  self.length = 0
end

function Queue:push(item)
  self.last = self.last + 1
  self.length = self.length + 1
  self[self.last] = item
end

function Queue:shift()
  -- Ignore the call if the queue is empty. Return
  if self.length == 0 then
    return
  end

  -- Get the first item
  local item = self[self.first]
  self[self.first] = nil
  self.length = self.length - 1

  if self.first == self.last then
    -- If it was the last item, reset the queue
    self:initialize()
  else
    -- Otherwise enqueue the next item.
    self.first = self.first + 1
  end

  return item
end

local ReadableStream = Object:extend()
uv.ReadableStream = ReadableStream

-- If there are more than this many buffered input chunks, readStop the source
ReadableStream.highWaterMark = 1
-- If there are less than this many buffered chunks, readStart the source
ReadableStream.lowWaterMark = 1

function ReadableStream:initialize()
  self.inputQueue = Queue:new()
  self.readerQueue = Queue:new()
end

function ReadableStream:read() return function (callback)
  self.readerQueue:push(callback)
  self:processReaders()
end end

function ReadableStream:processReaders()
  while self.inputQueue.length > 0 and self.readerQueue.length > 0 do
    local chunk = self.inputQueue:shift()
    local reader = self.readerQueue:shift()
    reader(nil, chunk)
  end
  local watermark = self.inputQueue.length - self.readerQueue.length
  if watermark > self.highWaterMark and not self.paused then
    self.paused = true
    self:pause()
  elseif watermark < self.lowWaterMark and self.paused then
    self.paused = false
    self:resume()
  end
end


local fs = {}
uv.fs = fs

function fs.open(path, flags, mode) return function (callback)
  -- TODO: register this resource with the resource cleaner
  native.fsOpen(path, flags, mode or "0644", callback or noop)
end end

function fs.read(fd, offset, size) return function (callback)
  native.fsRead(fd, offset, size, callback or noop)
end end

function fs.write(fd, offset, chunk) return function (callback)
  native.fsWrite(fd, offset, chunk, callback or noop)
end end

function fs.close(fd) return function (callback)
  -- TODO: free this resource from the resource cleaner
  native.fsClose(fd, callback or noop)
end end

function fs.stat(path) return function (callback)
  native.fsStat(path, callback or noop)
end end

function fs.fstat(fd) return function (callback)
  native.fsFstat(fd, callback or noop)
end end

function fs.lstat(path) return function (callback)
  native.fsLstat(path, callback or noop)
end end

fs.ReadStream = Object:extend()

fs.ReadStream.chunkSize = 65536

function fs.ReadStream:initialize(fd)
  self.fd = fd
  self.offset = 0
end

function fs.ReadStream:read() return function (callback)
  fs.read(self.fd, self.offset, self.chunkSize)(function (err, chunk)
    -- In case of error, close the fd and emit the error
    if err then
      fs.close(self.fd)()
      return callback(err)
    end
    local length = #chunk
    -- In case of data, move the offset and emit the chunk.
    if length > 0 then
      self.offset = self.offset + length
      return callback(nil, chunk)
    end
    -- Otherwise, it's EOF.  Close the fd and emit end.
    fs.close(self.fd)()
    callback()
  end)
end end

fs.WriteStream = Object:extend()

function fs.WriteStream:initialize(fd)
  self.fd = fd
  self.offset = 0
end

function fs.WriteStream:write(chunk) return function (callback)
  -- on eof, close the file
  if not chunk then
    return fs.close(self.fd)(callback)
  end
  -- Otherwise write the chunk
  fs.write(self.fd, self.offset, chunk)(function (err)
    -- On error, close the file and emit the error
    if err then
      fs.close(self.fd)()
      return callback(err)
    end
    callback()
  end)
end end

local handle = {}
uv.handle = handle

function handle:close() return function (callback)
  native.close(self, callback)
end end

function handle:setHandler(name, handler)
  native.setHandler(self, name, handler)
end

local stream = {}
uv.stream = stream

function stream:write(chunk) return function (callback)
  return native.write(self, chunk, callback)
end end

function stream:shutdown() return function (callback)
  native.shutdown(self, callback)
end end

function stream:readStart()
  return native.readStart(self)
end

function stream:readStop()
  return native.readStop(self)
end

function stream:listen(onConnection)
  return native.listen(self, onConnection)
end

function stream:accept(client)
  return native.accept(self, client)
end

stream.Stream = ReadableStream:extend()


function stream.Stream:initialize(handle)
  self.handle = handle
  -- Readable stuff
  ReadableStream.initialize(self)
  uv.handle.setHandler(handle, "data", function (chunk)
    self.inputQueue:push(chunk)
    self:processReaders()
  end)
  uv.handle.setHandler(handle, "end", function ()
    self.inputQueue:push()
    self:processReaders()
  end)
  uv.stream.readStart(handle)
end

function stream.Stream:pause()
  uv.stream.readStop(self.handle)
end

function stream.Stream:resume()
  uv.stream.readStart(self.handle)
end

function stream.Stream:write(chunk)
  if chunk then
    return uv.stream.write(self.handle, chunk)
  end
  return uv.stream.shutdown(self.handle)
end

local tcp = setmetatable({}, {__index=stream})
uv.tcp = tcp

function tcp:bind(host, port)
  return native.tcpBind(self, host, port)
end

function tcp.new()
  return native.newTcp()
end

function tcp.createServer(host, port, onConnection)
  local server = tcp.new()
  tcp.bind(server, host, port)
  tcp.listen(server, function ()
    local client = tcp.new()
    tcp.accept(server, client)
    onConnection(tcp.Stream:new(client))
  end)
end

uv.fiber = require('./fiber.lua')

return uv
