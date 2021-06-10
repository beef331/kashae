import std/[macros, tables, hashes]
export tables, hashes

type
  CacheOption* {.pure.} = enum
    clearParam         ## Adds `clearCache = false` to the procedure parameter list
    clearFunc          ## Allows calling `clearCache()` inside the procedure
    clearCacheAfterRun ## After running the function we clear the cache

  Cacheable*[K: Hash, V] = concept var c
    var a: Hash
    c.hasKey(a) is bool
    c[a] is V
    c[a] = V
    c.uncache()
    c.clear()

  CacheOptions = object
    flags*: set[CacheOption]
    size*: int
  AnyMatrix*[R, C: static int; T] = concept m, var mvar, type M
    M.ValueType is T
    M.Rows == R
    M.Cols == C

    m[int, int] is T
    mvar[int, int] = T

proc generateHashBody(params: seq[NimNode]): NimNode =
  ## Generates the block stmt that hashes the parameters
  result = newStmtList()
  let hashP = ident"hashParams"
  result.add quote do:
    var `hashP`: Hash = 0
  for param in params:
    result.add quote do:
      `hashP` = `hashP` !& `param`.hash
  result.add quote do:
    `hashP` = !$`hashP`
    `hashP`
  result = newBlockStmt(result)

var cacheType {.compileTime.}: NimNode

macro setCurrentCache*(a: Cacheable) =
  ## Changes the backing type from the macro call onwards.
  cacheType = a


proc uncache*(a: var OrderedTable) =
  for k in a.keys:
    a.del(k)
    break

setCurrentCache OrderedTable[Hash, int]

proc getParams(body: NimNode): seq[NimNode] =
  expectKind(body, nnkProcDef)
  for i in body[3][1..^1]:
    result.add i[0..^3]
  for x in result.mitems:
    if x.kind == nnkSym:
      x = ident $x

proc getCacheType(retT: NimNode): NimNode =
  result = cacheType.copyNimTree
  result[^1] = retT

proc cacheOptImpl(options: CacheOptions, body: NimNode): NimNode =
  ## Actual implementation of the cache macro
  let
    cacheName = gensym(nskVar, "cache")
    retT = body[3][0]
    clearCache = ident"clearCache"
    cacheType = getCacheType(body[3][0])

  assert retT.kind != nnkEmpty, "What do you want us to cache, farts?"

  var newBody = newStmtList()
  newBody.add quote do:
    var `cacheName` {.global.}: `cacheType`

  let
    params = body.getParams
    hashName = genSym(nskLet, "hash")
    lambdaName = genSym(nskLet, "lambda")
    lambda = body.copyNimTree()
  lambda[0] = newEmptyNode()

  let elseBody = newStmtList()
  elseBody.add newAssignment(ident"result", newCall(lambdaName,
      params)) # result = lambdaName(params)
  elseBody.add quote do: # Assign the value in the cache to result
    `cacheName`[`hashName`] = result

  let cacheSize = options.size
  if cacheSize > 0: # If we limit cache do that after each call
    elseBody.add quote do:
      if `cacheName`.len >= `cacheSize`:
        `cacheName`.uncache()

  newBody.add newLetStmt(hashName, params.generateHashBody()) # let hashName = block: hashParams()
  newBody.add quote do: # If we have the key get the value, otherwise run the procedure and do cache stuff
    if `cacheName`.hasKey(`hashName`):
      result = `cacheName`[`hashName`]
    else:
      let `lambdaName` = `lambda`
      `elseBody`

  result = body.copyNimTree()

  if clearParam in options.flags: # Adds the `clearCache = false` to the proc definition and logic to clear if true
    result[3].add newIdentDefs(clearCache, newEmptyNode(), newLit(false))
    newBody.insert 1, quote do:
      if `clearCache`:
        `cacheName`.clear

  if clearFunc in options.flags: # Adds a `clearCache` lambda internally for allowing clearing the cache through a function call
    let clearCacheLambda = ident"clearCache"
    newBody.insert 2, quote do:
      let `clearCacheLambda` {.used.} = proc = `cacheName`.clear

  if clearCacheAfterRun in options.flags: # Cmon you can read, clear after running
    let counterName = genSym(nskVar, "counter")
    newBody.insert 0:
      quote do:
        var `counterName` {.global.} = 0
        inc `counterName`
    newBody.add quote do:
      dec `counterName`
      if `counterName` == 0:
        `cacheName`.clear

  result[^1] = newBody # New body holds all the new logic we want

proc replaceSym(body, sym: NimNode) =
  for x in 0..<body.len:
    if body[x].kind == nnkCall and body[x][0] == sym and body.kind == nnkAsgn and body[0].kind == nnkIdent and body[0].eqIdent("result"):
      body[x][0] = ident($sym)
    else:
      body[x].replaceSym(sym)

proc cacheProcImpl(opts: CacheOptions, body: NimNode): NimNode =
  let 
    cacheName = gensym(nskVar, "cache")
    hashName = gensym(nskLet, "hash")
    params = getParams(body)
    hashGen = generateHashBody(params)
    cacheType = getCacheType(body[3][0])
    procCall = newCall(body[0], params)
  result = body.copyNimTree()
  result[0] = newEmptyNode()
  let elseBody = quote do:
    result = `procCall`
    `cacheName`[`hashName`] = result
  let cacheSize = opts.size
  if cacheSize > 0:
    elseBody.add quote do:
      if `cacheName`.len >= `cacheSize`:
        `cacheName`.uncache

  let newBody = quote do:
    var `cacheName` {.global.} : `cacheType`
    let `hashName` = `hashGen`
    if `hashName` in `cacheName`:
      result = `cacheName`[`hashName`]
    else:
      result = `procCall`
      `cacheName`[`hashName`] = result

  for x in result[3]: # Desym the formal params
    for y in 0 ..< x.len - 2:
      if x[y].kind == nnkSym:
        x[y] = ident $x[y]
  
  if clearParam in opts.flags: # Adds the `clearCache = false` to the proc definition and logic to clear if true
    let clearCache = ident"clearCache"
    result[3].add newIdentDefs(clearCache, newEmptyNode(), newLit(false)) 
    newBody.insert 1, quote do:
      if `clearCache`:
        `cacheName`.clear

  if clearCacheAfterRun in opts.flags: 
    # Cmon you can read, clear after running
    # Not very useful since only calls to this proc gets cached, 
    # we dont rewrite the entire proc to call this one
    newBody.add newCall(ident"clear", cacheName)

  result = newProc(newEmptyNode(), result[3][0..^1], newBody)

proc cacheImpl(options: CacheOptions, body: NimNode): NimNode =
  ## Used to support block style on multiple procedures
  case body.kind:
  of nnkProcDef:
    result = cacheOptImpl(options, body)
  of nnkSym:
    result = cacheProcImpl(options, body.getImpl)
  else:
    result = body
    for x in 0..<body.len:
      if result[x].kind == nnkProcDef:
        result[x] = cacheOptImpl(options, result[x])

macro cacheOpt*(options: static CacheOptions, body: untyped): untyped =
  ## Caches return value based off parameters, for quicker opertations.
  ## Due to reliance on a global variable it cannot be a `func`.
  ## All parameters need a `hash` procedure as the cache uses a table.
  cacheImpl(options, body)

macro cacheOpt*(cacheSize: static int, body: untyped): untyped =
  ## Variant that only accepts cache size
  cacheImpl(CacheOptions(size: cacheSize), body)

macro cacheOpt*(flags: static[set[CacheOption]], body: untyped): untyped =
  ## Variant that only accepts options
  cacheImpl(CacheOptions(flags: flags), body)

macro cache*(body: untyped): untyped =
  ## Simple Cache method, no options whatsoever
  cacheImpl(CacheOptions(), body)

macro cacheProc*(toCache: proc): untyped =
  ## Cache variant that makes any cacheable procedure cached
  result = cacheImpl(CacheOptions(), toCache)

macro cacheProc*(toCache: proc, flags: static set[CacheOption]): untyped =
  ## Cache Proc variant that takes in flags
  result = cacheImpl(CacheOptions(flags: flags), toCache)

macro cacheProc*(toCache: proc, size: static int): untyped =
  ## Cache Proc variant that takes in cache size
  result = cacheImpl(CacheOptions(size: size), toCache)

macro cacheProc*(toCache: proc, opts: static CacheOptions): untyped =
  ## Cache proc variant that takes full cache option object
  result = cacheImpl(opts, toCache)

when isMainModule:
  import std/math
  proc fib(n: int): int {.cache.} =
    if n <= 1:
      result = n
    else:
      result = fib(n - 1) + fib(n - 2)

  proc sqrt(a: float): float {.cacheOpt: 10.} =
    math.sqrt(a)

  proc log10(a: float32): float32 {.cacheOpt: {clearParam}.} =
    math.log10(a)

  proc `+%`(a, b: string): string {.cacheOpt: CacheOptions(size: 3, flags: {
      clearParam, clearFunc}).} =
    a & b

  cacheOpt(10):
    proc test(a, b: int): int = a + b
    proc hmm(a, b: int): int = a * b + b


  proc fibT(a: int): int {.cacheOpt: CacheOptions(flags: {clearCacheAfterRun}, size: 5).} =
    if a <= 1:
      result = a
    else:
      result = fibT(a - 1) + fibT(a - 2)

  proc uncachedFib(a: int): int =
    if a <= 1:
      result = a
    else:
      result = uncachedFib(a - 1) + uncachedFib(a - 2)
  
  let 
    cacheFib = cacheProc(uncachedFib)
    fibAfterRun = cacheProc(uncachedFib, {clearCacheAfterRun}) # Useless but yea
    fibLimitSize = cacheProc(uncachedFib, 10) # Above
    fibClearable = cacheProc(uncachedFib, {clearParam})

  # Clearable test
  echo fibClearable(40)
  echo fibClearable(40)
  echo fibClearable(40, true)

  # Cached test
  echo cacheFib(40)
  echo cacheFib(40)

  # Clear after run test
  echo fibAfterRun(40)
  echo fibAfterRun(40)

  # Limit size test
  echo fibLimitSize(40)
  echo fibLimitSize(40)

  # Assorted pragma tests
  echo fibT(40)
  echo fib(80)
  echo sqrt(32.0)
  echo log10(30f32)
  echo "A" +% "b"
  echo test(10, 20)
  echo hmm(30, 50)