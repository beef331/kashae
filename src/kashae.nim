import std/[macros, tables, hashes]
export tables, hashes

type 
  CacheOption* {.pure.} = enum
    clearParam ## Adds `clearCache = false` to the procedure parameter list
    clearFunc ## Allows calling `clearCache()` inside the procedure
  CacheOptions* = object
    flags*: set[CacheOption]
    size*: int


proc generateHashBody(params: seq[NimNode]): NimNode =
  result = newStmtList()
  let hashP = ident"hashParams"
  result.add nnkVarSection.newTree newIdentDefs(hashP, ident"Hash", newLit(0))
  for param in params:
    result.add quote do:
      `hashP` = `hashP` !& `param`.hash
  result.add quote do:
    `hashP` = !$`hashP`
    `hashP`
  result = newBlockStmt(result)

proc cacheImpl(options: CacheOptions, body: NimNode): NimNode =
  let 
    cacheName = gensym(nskVar, "cache")
    retT = body[3][0]
    clearCache = ident"clearCache"

  assert retT.kind != nnkEmpty, "What do you want us to cache, farts?"

  var newBody = newStmtList()
  newBody.add quote do:
    var `cacheName` {.global.}: OrderedTable[Hash,`retT`]

  let 
    params = block:
      var res: seq[NimNode]
      for i in body[3][1..^1]:
        res.add i[0..^3]
      res
    hashName = genSym(nskLet, "hash")
    lambdaName = genSym(nskLet, "lambda")
    lambda = body.copyNimTree()
  lambda[0] = newEmptyNode()
  
  let elseBody = newStmtList()
  elseBody.add newAssignment(ident"result", newCall(lambdaName, params))
  elseBody.add quote do:
    `cacheName`[`hashName`] = result
  let cacheSize = options.size
  if cacheSize > 0:
    elseBody.add quote do:
      if `cacheName`.len >= `cacheSize`:
        for k in `cacheName`.keys:
          `cacheName`.del(k)
          break
  
  newBody.add newLetStmt(hashName, params.generateHashBody())
  newBody.add quote do:
    if `cacheName`.hasKey(`hashName`):
      result = `cacheName`[`hashName`]
    else:
      let `lambdaName` = `lambda`
      `elseBody`

  result = body
  if clearParam in options.flags:
    result[3].add newIdentDefs(clearCache, newEmptyNode(), newLit(false))
    newBody.insert 1, quote do:
      if `clearCache`:
        `cacheName`.clear
  if clearFunc in options.flags:
    let clearCacheLambda = ident"clearCache"
    newBody.insert 2, quote do:
      let `clearCacheLambda` {.used.} = proc = `cacheName`.clear
  result[^1] = newBody

macro cache*(options: static CacheOptions, body: untyped): untyped =
  ## Caches return value based off parameters, for quicker opertations.
  ## Due to reliance on a global variable it cannot be a `func`.
  ## All parameters need a `hash` procedure as the cache uses a table.
  cacheImpl(options, body)

macro cache*(cacheSize: static int, body: untyped): untyped =
  ## Variant that only accepts cache size
  cacheImpl(CacheOptions(size: cacheSize), body)

macro cache*(flags: static[set[CacheOption]], body: untyped): untyped =
  ## Variant that only accepts options
  cacheImpl(CacheOptions(flags: flags), body)


const NoOptions* = CacheOptions() 


when isMainModule:
  import benchy
  import std/strformat

  proc fib(n: int): int =
    if n <= 1:
      result = n
    else:
      result = fib(n - 1) + fib(n - 2)

  proc fibCached(n: int): int {.cache: CacheOptions(flags: {clearParam}, size: 5).} =
    if n <= 1:
      result = n
    else:
      result = fibCached(n - 1) + fibCached(n - 2)

  const fibNum = 45

  timeit fmt"Un-kashaed Fib: {fibNum}", 1:
    keep fib(fibNum)

  timeit fmt"Clearing Kashaed Fib: {fibNum}", 1:
    keep fibCached(fibNum, true)

  timeit fmt"Kashaed Fib: {fibNum}", 1:
    keep fibCached(fibNum)
