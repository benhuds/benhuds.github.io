---
title: Yet Another Redis-backed Bloom Filter
author: Ben
mathjax: on
---

# Yet Another Redis-backed Bloom filter

Lately, I've been diving into [Redis](https://redis.io/).  And, like many others
learning Redis, I had no choice but to make my own [Redis-backed Bloom
filter](https://github.com/benhuds/yarb).  It was a short project just counting
lines of code, but gave me the opportunity to learn about Bloom filters from the
ground up, and in turn gave me a better understanding of why Redis is often used
for Bloom filters.

Redis is hugely popular because it's fast, simple, and open-source.  Why should
you care about Bloom filters at all, though?  Well, for the same sorts of
reasons - namely speed and simplicity.  They're also relatively easy to
implement. Bloom filters have found useful applications in various domains, and
are filtering spam emails from your inbox, [reducing unnecessary disk lookups
when running database queries](https://static.googleusercontent.com/media/research.google.com/en//archive/bigtable-osdi06.pdf),
and [improving network performance in many ways](https://www.eecs.harvard.edu/~michaelm/postscripts/im2005b.pdf).

In this tutorial, we'll walk through the basics of Bloom filters, and discuss a
simple implementation of a Redis-backed Bloom filter with the help of
[redis-py](https://github.com/andymccurdy/redis-py).

## 1.  Bloom filters: a primer

A [Bloom filter](https://en.wikipedia.org/wiki/Bloom_filter) is a
space-efficient probabilistic data structure which is primarily used to test for
approximate set membership.  It's space-efficient because it uses very little
space to store information about whether or not an element is in a set, and it's
probabilistic in that it can return false positives - so if you ask a Bloom
filter whether or not an element is in a set $S$, it'll either return "_probably
in $S$_," or "_definitely not in $S$_."  **If you need a quick answer to "is my
element in this set?" on a regular basis and can tolerate some false positives
every now and then, then a Bloom filter may be right for you.**
 
### 1.1.  Definitions

A Bloom filter $b$ is an array of $m$ bits.  It uses $k$ different hashing
functions$^1$ $h_1, ... ,h_k$ to insert elements into and check membership for a
set $S$.

- The empty set $\emptyset$ is represented by a Bloom filter with all bits set
  to 0.
- To add an element $x$ to $S$, set $b$[$h_1 (x)$ mod $m$] = ... = $b$[$h_k (x)$
  mod $m$] = 1.
- To check whether an element $x$ might be in $S$, check if $b$[$h_1 (x)$ mod
  $m$] = ... = $b$[$h_k (x)$ mod $m$] = 1.  If true, then $x$ is probably in
$S$.  If false, then $x \notin S$.

In plain English:

- If you want to add an element to the set, you feed it to all of the hash
  functions to get some numbers which represent positions in the array.  Set all
of the bits at these positions to 1.
- If you want to see if an element is part of the set, then (once again) feed
  that element to the hash functions to get some numbers which represent
positions in the bit array.  If the element was previously inserted, then all of
the bits at the positions given to you by the hash functions should have been
set to 1.  Therefore, if any of the bits at those positions are set to 0, then
your number is definitely not in the set.  Otherwise, if all of the bits at
those positions are set to 1, then your number is probably in the set.

Notice that computing array positions modulo the Bloom filter size is naturally
prone to collision, and is the main source of false positives.  There are ways
to compute the optimal number of hash functions and Bloom filter size given the
expected size of your set and acceptable false positive rate, but I won't get
into that here since the [Wikipedia article on Bloom
filters](https://en.wikipedia.org/wiki/Bloom_filter#Probability_of_false_positives)
already provides a pretty thorough treatment.

### 1.2.  Example

Let's walk through a simple example to illustrate inserting elements and finding
false positives.  Let $b$ be our Bloom filter, a bit array of 10 bits, and let
our set $S$ = $\emptyset$, the empty set.  Let's also have two hash functions,
$h_1$ and $h_2$ as follows:

- $h_1(x)$ = $3x + 1$
- $h_2(x)$ = $123x + 4$

Keep in mind these are random functions for the purposes of this example.  Since
we're starting with the empty set, our Bloom filter is just a list of 0's:

[0,0,0,0,0,0,0,0,0,0]

Let's insert a couple of elements, starting with the number 10.  Now $S =
\{10\}$.  By definition, to represent this new member with our Bloom filter, we
need to set $b$[$h_1 (10)$ mod 10] = ... $b$[$h_2 (10)$ mod 10] = 1:

- $h_1(10)$ mod 10 = 1, so set $b$[1] = 1.
- $h_2(10)$ mod 10 = 0, so set $b$[4] = 1.

Now our Bloom filter is:

[0,1,0,0,1,0,0,0,0,0]

Let's keep going and insert the number 21 into our set, so $S = \{10, 21\}$.
Using the same process as above:

- $h_1(21)$ mod 10 = 4, so set $b$[4] = 1.
- $h_2(21)$ mod 10 = 7, so set $b$[7] = 1.

At this stage, our Bloom filter is:

[0,1,0,0,1,0,0,1,0,0]

Time to do some membership tests.  Let's see if $15 \in S$:

- $h_1(15)$ mod 10 = 6.  $b$[6] = 0.
- $h_2(15)$ mod 10 = 9.  $b$[9] = 0.

$b$[6] and $b$[9] are both 0, so our Bloom filter returns $15 \notin S$ as
expected.  Now let's see if the number 20 is in our set:

- $h_1(20)$ mod 10 = 1.  $b$[1] = 1.
- $h_2(20)$ mod 10 = 4.  $b$[4] = 1.

$b$[1] = $b$[4] = 1, so our Bloom filter returns that 20 is probably in $S$.
Notice this is a false positive, since we only have $S = \{10, 21\}$.
 
## 2.  Putting it all together

It's pretty straightforward to bake the above definitions together with
[redis-py](https://github.com/andymccurdy/redis-py), a popular Redis Python
client, to implement a simple Redis-backed Bloom filter in Python.  Redis' speed
(especially in simple CRUD operations), plus its support for bit arrays, makes
it suitable for Bloom filters.

After importing redis-py using `import redis`, `__init__` method of my Bloom
filter class is as follows:

``` python
def __init__(self, connection, name, m, k):
    self.connection = connection
    self.name = name
    self.m = m
    self.k = k
``` 

where $connection$ is the connection to the Redis server, $name$ is the Redis
key for the Bloom filter, and $m$ and $k$ are the size of the Bloom filter and
number of hash functions respectively, as described in 1.1.

We can use Redis' `SETBIT` and `GETBIT` commands to manipulate bit arrays.
Remember: speed matters.  Redis'
[pipelining](https://redis.io/topics/pipelining) feature allows you to ship
multiple commands to the server in the same round to avoid multiple round trips.
You'll want to use this when implementing a Bloom filter, since Bloom filters
require multiple `SETBIT` operations in each insert (and multiple `GETBIT`
operations in each membership query).

Here's the function to `insert` an element (`key`) into a Bloom filter:

``` python
def insert(self, key):
    pipe = self.connection.pipeline()
    for offset in self.calculate_offsets(key):
        pipe.setbit(self.name, offset, 1)
    pipe.execute()
```

where `calculate_offsets` is a function to calculate the positions in the array
which we need to set to 1.  Notice we wrap multiple `SETBIT` operations in the
same `pipeline` to send them to the server at the same time and avoid multiple
trips.  The function to query set membership, which I've called `contains`, is
similar:

``` python
def contains(self, key):
    pipe = self.connection.pipeline()
    for offset in self.calculate_offsets(key):
        pipe.getbit(self.name, offset)
    res = pipe.execute()
    return all(res)
```

The difference here is that we store the resulting list of the bits' values
returned by each `GETBIT` command, and use a neat built-in function to check if
`all` the values in the list are equal to 1. 

### 2.1.  Remark on hash functions

Choose your hash functions wisely.  Put simply: the slower your hash functions
are, the slower your Bloom filter will be, and the slower you will be at
whatever you're using them for.  Widely-used hash functions like SHA-256 and MD5
are in a class of functions known as [_cryptographic hash
functions_](https://en.wikipedia.org/wiki/Cryptographic_hash_function), which
ensure certain important security properties, such as collision resistance,
pre-image resistance, and the avalanche effect.  On the other hand,
_non-cryptographic hash functions_, such as
[FNV](http://www.isthe.com/chongo/tech/comp/fnv/index.html),
[MurmurHash](https://en.wikipedia.org/wiki/MurmurHash), and Google's
[CityHash](https://github.com/google/cityhash), sacrifice some of these
properties in exchange for much better speed.  I've seen both types used in the
wild, but since Bloom filters emphasize quickness, I've used a couple of
non-cryptographic hash functions in my implementation.

### 2.2.  A naive approach to bulk inserts

You could write a bulk insert function to pipeline a bunch of inserts to the
server at once, say if you needed to initially populate the Bloom filter.  I cut
more than half of the time needed to insert 109,582 English words into a
1,000,000-bit Bloom filter with 3 hash derivations using the function below:

``` python
def bulk_insert(self, keys):
    pipe = self.connection.pipeline()
    for k in keys:
        for offset in self.calculate_offsets(k):
            pipe.setbit(self.name, offset, 1)
    pipe.execute()
```

The *proper* way to handle mass inserts in Redis, though, is to use the [Redis
protocol](https://redis.io/topics/mass-insert).

## 3.  Summary

Learning about Redis inadvertedly led me to brush the surface of probabilistic
data structures.  By design, Bloom filters give rise to many questions, as well
as the opportunity to extend their basic functionality to answer some of these
questions.  I may follow up this post with a quick write-up on [Cuckoo
filters](https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf), a recent
alternative to Bloom filters which achieve better performance and support
deletion.

---

$^1$ [Bloom's original paper](http://dmod.eu/deca/ft_gateway.cfm.pdf) states

> *"each message in the set to be stored is hash coded into a number of distinct bit addresses, say $a_1$, $a_2$, ..., $a_d$.  Finally, all $d$ bits addressed by $a_1$ through $a_d$ are set to 1."*

Obviously, having $d$ different hash functions will do the trick, but there are
other methods to generate array positions for your Bloom filter.  For example,
you could use one hash function with $d$ different seed values to get $d$
different array positions (e.g. position 1 = element hashed with 1 as seed
value, position 2 = element hashed with 2 as seed value, and so on).  In my
implementation, I used a trick which [simulates many hash functions with only
two hash functions](https://www.eecs.harvard.edu/~michaelm/postscripts/rsa2008.pdf).
 
