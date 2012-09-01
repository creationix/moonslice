local native = require('uv_native')
local Object = require('core').Object
local coroutine = require('coroutine')
local debug = require 'debug'

local function noop() end
local uv = {}

local Queue = Object:extend()

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

stream.Stream = Object:extend()

-- If there are more than this many buffered input chunks, readStop the source
stream.Stream.highWaterMark = 1
-- If there are less than this many buffered chunks, readStart the source
stream.Stream.lowWaterMark = 1

function stream.Stream:initialize(handle)
  self.handle = handle
  -- Readable stuff
  self.inputQueue = Queue:new()
  self.readerQueue = Queue:new()
  uv.handle.setHandler(handle, "data", function (chunk)
    self.inputQueue:push(chunk)
    self:processReaders()
  end)
  uv.stream.readStart(handle)
end

function stream.Stream:read() return function (callback)
  self.readerQueue:push(callback)
  self:processReaders()
end end

function stream.Stream:processReaders()
  while self.inputQueue.length > 0 and self.readerQueue.length > 0 do
    local chunk = self.inputQueue:shift()
    local reader = self.readerQueue:shift()
    reader(nil, chunk)
  end
  local watermark = self.inputQueue.length - self.readerQueue.length
  if watermark > self.highWaterMark and not self.paused then
    self.paused = true
    uv.stream.readStop(self.handle)
  elseif watermark < self.lowWaterMark and self.paused then
    self.paused = false
    uv.stream.readStart(self.handle)
  end
end

function stream.Stream:write(chunk) 
  if chunk then
    return uv.stream.write(self.handle, chunk)
  end
  return uv.stream.shutdown(self, handle)
end

local tcp = setmetatable({}, {__index=stream})
uv.tcp = tcp

function tcp:bind(host, port)
  return native.tcpBind(self, host, port)
end

function tcp.new()
  return native.newTcp()
end

local fiber = {}
uv.fiber = fiber

local fibers = {}

local function formatError(co, err)
  local stack = debug.traceback(co, tostring(err))
  if type(err) == "table" then
    err.message = stack
    return err
  end
  return stack
end

local function check(co, success, ...)
  local fiber = fibers[co]

  if not success then
    local err = formatError(co, ...)
    if fiber and fiber.callback then
      return fiber.callback(err)
    end
    error(err)
  end
  
  -- Abort on non-managed coroutines.
  if not fiber then
    return ...
  end
    
  -- If the fiber is done, pass the result to the callback and cleanup.
  if not fiber.paused then
    fibers[co] = nil
    if fiber.callback then
      fiber.callback(nil, ...)
    end
    return ...
  end
  
  fiber.paused = false
end

-- Create a managed fiber as a continuable
function fiber.new(fn, ...)
  local args = {...}
  local nargs = select("#", ...)
  return function (callback)
    local co = coroutine.create(fn)
    local fiber = {
      callback = callback
    }
    fibers[co] = fiber
    
    check(co, coroutine.resume(co, unpack(args, 1, nargs)))
  end
end

function fiber.wait(continuation)
  
  if type(continuation) ~= "function" then
    error("Continuation must be a function.")
  end
  
  -- Find out what thread we're running in.
  local co, isMain = coroutine.running()

  -- When main, Lua 5.1 `co` will be nil, lua 5.2, `isMain` will be true
  if not co or isMain then
    error("Can't wait from the main thread.")
  end

  local fiber = fibers[co]

  -- Execute the continuation
  local async, ret, nret
  continuation(function (...)

    -- If async hasn't been set yet, that means the callback was called before
    -- the continuation returned.  We should store the result and wait till it
    -- returns later on.
    if not async then
      async = false
      ret = {...}
      nret = select("#", ...)
      return
    end
    
    -- Callback was called we can resume the coroutine.
    -- When it yields, check for managed coroutines
    check(co, coroutine.resume(co, ...))

  end)

  -- If the callback was called early, we can just return the value here and
  -- not bother suspending the coroutine in the first place.
  if async == false then
    return unpack(ret, 1, nret)
  end
  
  -- Mark that the contination has returned.
  async = true
  
  -- Mark the fiber as paused if there is one.
  if fiber then fiber.paused = true end
  
  -- Suspend the coroutine and wait for the callback to be called.
  return coroutine.yield()
end

-- This is a wrapper around wait that strips off the first result and 
-- interprets is as an error to throw.
function fiber.await(...)
  -- TODO: find out if there is a way to count the number of return values from
  -- fiber.wait while still storing the results in a table.
  local results = {fiber.wait(...)}
  local nresults = sel
  if results[1] then
    error(results[1])
  end
  return unpack(results, 2)
end

return uv
