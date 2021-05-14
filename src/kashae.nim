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

proc cacheProcImpl(options: CacheOptions, body: NimNode): NimNode =
  ## Actual implementation of the cache macro
  let
    cacheName = gensym(nskVar, "cache")
    retT = body[3][0]
    clearCache = ident"clearCache"
    cacheType = cacheType.copyNimTree
  cacheType[^1] = retT

  assert retT.kind != nnkEmpty, "What do you want us to cache, farts?"

  var newBody = newStmtList()
  newBody.add quote do:
    var `cacheName` {.global.}: `cacheType`

  let
    params = block: # Extract all parameter idents
      var res: seq[NimNode]
      for i in body[3][1..^1]:
        res.add i[0..^3]
      res
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

proc cacheImpl(options: CacheOptions, body: NimNode): NimNode =
  ## Used to support block style on multiple procedures
  if body.kind == nnkProcDef:
    result = cacheProcImpl(options, body)
  else:
    result = body
    for x in 0..<body.len:
      if result[x].kind == nnkProcDef:
        result[x] = cacheProcImpl(options, result[x])

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


  import benchy
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

  timeIt "clearcache":
    keep fibT(40)
  timeIt "uncached", 1:
    keep uncachedFib(40)

  echo fib(80)
  echo sqrt(32.0)
  echo log10(30f32)
  echo "A" +% "b"
  echo test(10, 20)
  echo hmm(30, 50)
