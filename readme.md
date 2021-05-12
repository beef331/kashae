# Kashae - Yep, it's just `cache`
Kashae is a small implementation of caching return values for speeding up repetitive operations with the same parameters.

## How to use
After installing `kashae`, simply annotate your procedure with `{.cache.}` to enable an unclearable  "unlimited" cache.
For instance with recursive Fibonacci number calculator:
```nim
proc fib(n: int): int {.cache.} =
  if n <= 1:
    result = n
  else:
    result = fib(n - 1) + fib(n - 2)
```
But shucks, what if we want to clear that pesky cache? Well this can be done using `cacheOpt:`. One way is to do: 
```nim
proc fib(n: int): int {.cacheOpt: {clearParam}.}
# This is now expanded to 
proc fib(n: int, clearCache = false): int 
```
In the above example you can now do `fib(10, true)` and it'd run `foo`'s logic after clearing the cache, rebuilding it as it goes. 
Secondly you can do:
```nim
proc fib(n: int): int {.cacheOpt: {clearFunc}.}
```
And now `clearCache()` can be called inside the function when you want to clear the cache based off some conditional like if the sun is in your eyes. If you start running out of ram and cannot find a reliable source to download it, you may want to consider limiting the cache size. Which can be done in the following ways:

```nim
proc fib(n: int): int {.cacheOpt: CacheOptions(flags: {clearParam}, size: 10).} # Hey we want options
proc fib(n: int): int {.cacheOpt: 10.} # Freewill does not exist
```
Now you might be scratching your head thinking "but why?", two words, well one root word twice, speedy speed. Even with a cleared cache you can vastly outperform the equivalent without a cache due to calculations being in the table, my timing of the above `fib` without cache, clearing the cache, and with a built cache are as follows:
```
name ............................... min time      avg time    std dv   runs
Un-kashaed Fib: 45 .............. 6970.467 ms   7014.019 ms   ±32.373    x10
Clearing Kashaed Fib: 45 ........... 0.002 ms      0.003 ms    ±0.002    x10
Kashaed Fib: 45 .................... 0.000 ms      0.000 ms    ±0.000    x10
```
## Implementation details
Presently Kashae by default uses a Ordered Table removing the oldest value first, which is beneficial for operations like the `fib` example since you have many branches that call values below it.

If you want to use a different type for the cache you can! It just requires matching the following concept signature.
```nim
  Cacheable*[K: Hash, V] = concept var c
    var a: Hash
    c.hasKey(a) is bool
    c[a] is V
    c[a] = K
    c.uncache()
    c.clear()

# If you prefer the Nim proc definitions:

  proc hasKey*[K, V](col: YourCollection, v: V): bool
  proc `[]`[K, V](col: YourCollection, k: K): V
  proc `[]=`[K, V](col: var YourCollection, k: K, v: V)
  proc uncache(col: var YourCollection)
  proc clear(col: var YourCollection)
```
After implementing all of those you can simply do `setCurrentCache YourCollection[Hash, int]`, `int` can be replaced with any type you desire, but is needed to match the concept.