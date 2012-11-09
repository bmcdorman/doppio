win = window

root = win.node = {}
basename = (path) -> cmps = path.split '/'; return cmps.pop()
win.require = (path) ->
  [name, ext] = (basename path).split '.'
  window[name] ?= {}

_ = require '../third_party/_.js'

"use strict"

# Our 'file descriptor'
class DoppioFile
  @fromJSON: (path, rawData) ->
    data = JSON.parse rawData
    new DoppioFile(path, data.data, data.mtime)

  constructor: (@path, @data = "", @mtime = (new Date).getTime(), @mod = false) ->

  read: (length, pos) ->
    return @data unless length?
    @data.substr(pos, length)

  # TODO: We only append to the end of files...
  write: (newData) -> @mod = true; @data += newData; @

  toJSON: ->
    JSON.stringify
      data: @data
      mtime: @mtime

# Helper object. Used by some FileSources to maintain an index of files.
class FileIndex
  constructor: (initial_index) ->
    if initial_index?
      @index = initial_index
    else
      @index = {}

  # Get subcomponents of the given path.
  _subcomponents: (path) ->
    components = path.split '/'
    # Get rid of first slash
    components.shift()
    # Special case: Root
    if components.length == 1 and components[0] == ''
      return []
    return components
  _add_file: (components, fname, file) ->
    dir = @_mkdir(components)
    dir[fname] = file
    return
  _mkdir: (components) ->
    cur_dir = @index
    for c in components
      if !cur_dir[c]? then cur_dir[c] = {}
      cur_dir = cur_dir[c]
    return cur_dir
  _get: (components) ->
    cur_dir = @index
    for c in components
      if !cur_dir[c]? then return false
      cur_dir = cur_dir[c]
    return cur_dir
  _is_directory: (obj) -> obj != null and !(obj instanceof DoppioFile)

  # Add the given file to the index. Implicitly creates directories if needed
  # and overwrites things without checking.
  add_file: (path, file) ->
    components = @_subcomponents(path)
    fname = components.pop()
    @_add_file(components, fname, file)
    return
  # Retrieves the given file. Returns 'false' if the file does not exist, or if
  # it is a directory. Otherwise, returns the file (which may be null).
  get_file: (path) ->
    components = @_subcomponents(path)
    f = @_get(components)
    if f != false and !@_is_directory(f)
      return f
    return false
  # Returns a directory listing, or null if the directory does not exist.
  ls: (path) ->
    components = @_subcomponents(path)
    dir = @_get(components)
    if dir != false and @_is_directory(dir)
      return Object.keys(dir)
    return null
  # Makes the given directory. Implicitly creates needed subdirectories.
  mkdir: (path) ->
    components = @_subcomponents(path)
    @_mkdir(components)
    return
  # Removes the given path, directory or not, from the index. This is a
  # recursive delete. Returns the paths to the files that were deleted if this
  # was a directory, otherwise returns true if a file was deleted, false if
  # the path did not exist.
  rm: (path) ->
    components = @_subcomponents(path)
    name = components.pop()
    parent = @_get(components)
    ret = false
    if parent? and parent != false
      if parent[name]?
        ret = true
        obj = parent[name]
        if @_is_directory(obj)
          ret = Object.keys(obj)
        delete parent[name]
    return ret

# Interface for a FileSource. Somewhat of a misnomer, as they are also sinks...
class FileSource
  # Set to 'true' if this FileSource is redundant to another in some way.
  # This signals that it should be written to / deleted from, even if another
  # applicable source has an identical file or directory path
  redundant_storage: false
  # A handy method for sources that store/retrieve data using a relative file
  # name.
  _trim_mnt_pt: (path) -> path.slice(@mnt_pt.length)

  constructor: (@mnt_pt) ->

  # INTERFACE METHODS
  # Fetches file at path; DoppioFile for success, null for failure.
  fetch: (path) -> null
  # Stores file to path; true for success, false for failure.
  store: (path, file) -> false
  # Removes the file or folder at the given path. Returns true for success.
  # If there are files in the folder, it automatically recurses.
  rm: (path) -> false
  # Returns a directory listing for the given path, or null if it does not
  # exist.
  ls: (path) -> null

# Composes multiple file sources into one file source. Prioritizes file sources
# in the order in which they are added.
class CompositedFileSource extends FileSource
  # Returns 'true' if the given path is in the given mount point.
  _in_mnt_pt: (path, mnt_pt) -> mnt_pt == '/' or path == mnt_pt or (path.slice(0, mnt_pt.length) == mnt_pt and path[mnt_pt.length] == '/')
  _get_applicable_sources: (path) ->
    applicable = []
    for a_mnt_pt in @mnt_pts
      if @_in_mnt_pt(path, a_mnt_pt)
        applicable.push(@sources[a_mnt_pt])
    return applicable

  constructor: (mnt_pt, inpt_sources = []) ->
    super(mnt_pt)
    @sources = {}
    @mnt_pts = []
    @redundant_storage = false
    for source in inpt_sources
      @add_source(source)

  add_source: (source) ->
    @sources[source.mnt_pt] = source
    @mnt_pts.push(source.mnt_pt)
    if source.redundant_storage == true
      @redundant_storage = true
    return

  fetch: (path) ->
    applicable = @_get_applicable_sources(path)
    for parent in applicable
      f = parent.fetch(path)
      if f?
        return f
    return null

  store: (path, file) ->
    applicable = @_get_applicable_sources(path)
    stored = false
    for source in applicable
      if (stored and source.redundant_storage) or !stored
        stored = source.store(path, file) || stored
    return stored

  rm: (path) ->
    applicable = @_get_applicable_sources(path)
    removed = false
    for source in applicable
      if (removed and source.redundant_storage) or !removed
        removed = source.rm(path) || removed
    return removed

  ls: (path) ->
    applicable = @_get_applicable_sources(path)
    list = null
    for source in applicable
      src_list = source.ls(path)
      if src_list?
        if list?
          list = _.union(list, src_list)
        else
          list = src_list
    return list

class LocalStorageSource extends FileSource
  redundant_storage: true
  constructor: (mnt_pt) ->
    super(mnt_pt)
    # Index of all files in LS.
    @index = new FileIndex()
    # Initialize index w/ LS files and directories.
    for path of localStorage
      @index.add_file(path, null)

  fetch: (path) -> if localStorage[path]? then DoppioFile.fromJSON(path, localStorage[path]) else null
  store: (path, file) ->
    if file.mod
      localStorage[path] = file.toJSON()
      @index.add_file(path, file)
    true
  rm: (path) ->
    listing = @index.rm(path)
    if typeof listing != 'boolean'
      for item in listing
        itPath = path + '/' + item
        if localStorage[itPath]? then delete localStorage[itPath]
    else if localStorage[path]?
      delete localStorage[path]
    else
      return false
    return true

  ls: (path) -> @index.ls(path)

class WebserverSource extends FileSource
  _download_file: (path) ->
    data = null
    $.ajax path, {
      type: 'GET'
      dataType: 'text'
      async: false
      beforeSend: (jqXHR) -> jqXHR.overrideMimeType('text/plain; charset=x-user-defined')
      success: (theData) -> data = theData
    }
    return data
  constructor: (mnt_pt, listings_path) ->
    super(mnt_pt)
    if listings_path?
      idx_data = @_download_file(listings_path)
    if idx_data?
      @index = new FileIndex(JSON.parse(idx_data))
    else
      @index = new FileIndex()
  fetch: (path) ->
    trim_path = @_trim_mnt_pt(path)
    file = null
    data = @_download_file(trim_path)
    if data? then file = new DoppioFile(path, data)
    return file
  ls: (path) -> @index.ls(path)

# Wraps another FileSource and acts as its cache.
class CacheSource extends FileSource
  constructor: (mnt_pt, src) ->
    super(mnt_pt)
    @src = src
    @redundant_storage = src.redundant_storage
    @index = new FileIndex()
  fetch: (path) ->
    f = @index.get_file(path)
    if f == false
      f = @src.fetch(path)
      if f?
        @index.add_file(path, f)
    return f
  store: (path, file) ->
    if @src.store(path, file)
      @index.add_file(path, file)
      return true
    return false
  rm: (path) ->
    if @src.rm(path)
      @index.rm(path)
      return true
    return false
  ls: (path) -> @src.ls(path)

# Stores the File System's current state.
class FSState
  constructor: ->
    # Files fetched from webserver are always represented internally as relative
    # to home.
    #(mnt_pt, inpt_sources = [])
    @home = '/home/doppio'
    @pwd = @home
    mainSource = new CompositedFileSource('/', [new LocalStorageSource('/'), new WebserverSource('/home/doppio', '/browser/listings.json')])
    @files = new CacheSource('/', mainSource)

  # Canonicalizes the given path.
  resolve: (path) ->
    components = path.split '/'
    absolute = path[0] == '/'
    for c, idx in components
      components[idx] = '' if c == '.'
      components[idx] = @home if c == '~'
    if !absolute
      pwdCmps = @pwd.split '/'
      for i in [pwdCmps.length - 1..0] by -1
        components.unshift(pwdCmps[i])
    for c, idx in components
      if c == '..'
        processed = false
        i = idx-1
        while !processed
          if i < 0 then processed = true
          if components[i] != ''
            components[i] = ''
            components[idx] = ''
            processed = true
          i--
    # remove repeated //s
    path = (c for c, idx in components when c != '').join '/'
    if path[0] != '/'
      path = '/' + path
    return path

  # Retrieves a file from the file system. Creates a new one if needed.
  # Mode is 'r' for read, 'w' for write+read, 'a' for append+read
  open: (path, mode = 'r') ->
    path = @resolve path
    if @is_directory(path)
      return null
    # Start fresh.
    if mode == 'w'
      f = new DoppioFile(path)
      f.mod = true
      return f
    f = @files.fetch path
    if !f?
        return null
    f

  close: (file) -> @files.store(file.path, file); file.mod = false

  list: (path) ->
    path = @resolve path
    @files.ls(path)

  is_file: (path) ->
    path = @resolve path
    @files.fetch(path)?

  is_directory: (path) -> @list(path)?

  rm: (path, isDir = false) ->
    path = @resolve path
    isActuallyDir = @is_directory(path)
    if isActuallyDir != isDir
      return false
    @files.rm(path)

  chdir: (dir) ->
    dir = @resolve(dir)
    if @is_directory dir
      @pwd = dir
      dir
    else
      null


# Currently a singleton.
fs_state = new FSState()

################################################################################
# NODE EMULATION
################################################################################

class Stat
  @fromPath: (path) ->
    if fs_state.is_directory path
      stat = new Stat
      stat.size = 1
      stat.mtime = (new Date).getTime()
      stat.is_file = false
      stat.is_directory = true
      stat
    else
      file = fs_state.open path, 'r'
      return null unless file?
      new Stat file

  constructor: (@file) ->
    if @file?
      @size = @file.data.length
      @mtime = @file.mtime
      @is_file = true
      @is_directory = false

  isFile: -> @is_file

  isDirectory: -> @is_directory

# This is a global in Node.JS
class win.Buffer
  constructor: (obj) ->
    if obj instanceof Array
      @array = obj
    else # assume num
      @array = new Array obj

  readUInt8: (i) -> util.int2uint @array[i], 1

# Node's filesystem API, implemented as a wrapper around FSState.
root.fs =
  statSync: (path) ->
    path = fs_state.resolve path
    # XXX: Hack.
    unless path is '/System/Library/Frameworks/JavaVM.framework/Classes/classes.jar'
      return Stat.fromPath path
    stat = new Stat
    stat.size = 21090
    stat.mtime = (new Date).getTime() - 10000
    stat.is_file = true
    stat.is_directory = false
    stat

  fstatSync: (fp) -> new Stat(fp)

  openSync: (path, mode) ->
    # 'r' - Open file for reading. An exception occurs if the file does not exist.
    # 'w' - Open file for writing. The file is created (if it does not exist) or truncated (if it exists).
    # 'a' - Open file for appending. The file is created if it does not exist.
    # Normalize 'mode' to the three we care about
    if 'w' in mode then mode = 'w'
    else if 'a' in mode then mode = 'a'
    else mode = 'r'
    f = fs_state.open(path, mode)
    unless f?
      err = new Error
      err.code = 'ENOENT'
      throw err
    f

  readSync: (fd, buf, offset, length, pos) ->
    data = fd.read(length, pos)
    for d, i in data
      buf.array[offset+i] = data.charCodeAt(i) & 0xFF
    data.length

  readFileSync: (path) ->
    f = fs_state.open(path, 'r')
    throw "File does not exist." if !f?
    return f.data

  writeFileSync: (path, data) ->
    f = fs_state.open(path, 'w')
    f.write(data)
    fs_state.close(f)

  writeSync: (fd, buffer, offset, len) ->
    # TODO flush occasionally?
    fd.write(String.fromCharCode(buffer.readUInt8(i) for i in [offset...offset+len] by 1).join '')

  closeSync: (fd) -> fs_state.close(fd)

  readdirSync: (path) ->
    dir_contents = fs_state.list(path)
    throw "Could not read directory '#{path}'" unless dir_contents
    return dir_contents

  unlinkSync: (path) ->
    if !fs_state.rm(path)
      throw "Could not unlink '#{path}'"

# Node's Path API
root.path =
  normalize: (path) -> path
  resolve: (path) -> fs_state.resolve(path)

root.process =
  cwd: -> fs_state.pwd
  chdir: (dir) ->
    absdir = fs_state.chdir dir
    throw "Invalid directory" unless absdir?
    absdir
