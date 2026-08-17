# Examples

## Contents

| Path | What it is |
|---|---|
| [`wordcount/`](wordcount) | A production-shaped MapReduce job: `Tool` interface, counters, a combiner, unit tests |
| [`run-wordcount.sh`](run-wordcount.sh) | Stages input, runs the job, prints the top 20 words |
| [`hdfs-basics.sh`](hdfs-basics.sh) | Guided tour of the HDFS commands worth knowing |
| [`data/`](data) | Sample corpus |

## Running it

```bash
make up            # cluster
make example       # build the jar with Maven
make wordcount     # run it
```

`run-wordcount.sh` falls back to Hadoop's bundled `hadoop-mapreduce-examples`
jar if the project jar has not been built, so `make wordcount` works before you
have Maven installed.

Bare metal, or with your own paths:

```bash
./examples/run-wordcount.sh /my/input /my/output
```

## What the WordCount example demonstrates

It is 200 lines rather than the canonical 40, and every extra line is there for a
reason worth knowing.

### `Tool` and `ToolRunner`

```java
public class WordCount extends Configured implements Tool { ... }
ToolRunner.run(new Configuration(), new WordCount(), args);
```

This is what makes `-D`, `-files`, `-libjars` and `-archives` work. A driver with
a plain `main` silently ignores all of them, and "my `-D` had no effect" is a
confusion nobody needs to earn:

```bash
yarn jar wordcount-1.0.0.jar -D mapreduce.job.reduces=4 /input /output
```

### `setJarByClass`

```java
job.setJarByClass(WordCount.class);
```

Tells YARN which jar to ship to every container. Omit it and the job works
locally but fails on the cluster with `ClassNotFoundException`, because the local
classpath happened to already have the classes.

### Object reuse in the hot path

```java
private final Text outputKey = new Text();
private static final IntWritable ONE = new IntWritable(1);
```

`map()` runs millions of times per task. Allocating a `Text` and an `IntWritable`
per token is the most common source of avoidable GC pressure in MapReduce code.

### The combiner is the reducer — and why that is allowed

```java
job.setCombinerClass(IntSumReducer.class);
```

Legal only because summation is associative and commutative. The framework
decides freely whether to run a combiner, how many times, and over which
subsets. A combiner computing an average would silently produce wrong answers,
and nothing in the API would stop you.

### The reused value in `reduce()`

The `Iterable<IntWritable>` hands back the **same instance** with a new value on
each iteration. Collecting those references gives you *n* copies of the last
value — a classic bug, called out in the code and covered by a test.

### Counters

```java
context.getCounter(Counter.TOKENS_EMITTED).increment(1);
```

Visible in the job summary, the ResourceManager UI and `mapred job -counter`.
Cheap, aggregated across every task for free, and the fastest way to answer "how
much of my input was garbage" without adding a debugging job.

The example also tracks singleton words: a high singleton ratio almost always
means the tokenizer is letting punctuation or markup through.

### Configurable behaviour

| Property | Default | Effect |
|---|---|---|
| `wordcount.case.insensitive` | `true` | Fold to lower case before counting |
| `wordcount.min.token.length` | `1` | Drop shorter tokens |
| `wordcount.output.overwrite` | `false` | Delete the output directory first |
| `mapreduce.job.reduces` | `1` | Reducer count, and therefore output file count |

MapReduce refusing to write into an existing output directory is a feature — it
stops a re-run from half-overwriting results — so removal has to be requested
explicitly.

## Tests

```bash
cd examples/wordcount && mvn test
```

`Mapper.Context` is an inner interface with no public implementation, so the
tests mock it and assert on what was written and which counters moved. MRUnit
used to fill this role but has been retired from Apache.

The reducer tests include one that feeds pre-aggregated input (`3, 2, 1` instead
of six ones) — that is the property which makes the class a valid combiner, so
it is worth a test rather than a comment.

## Exercises

1. **Second sort job.** The output is sorted by word, not by count. Write a
   second job that reads the output and emits the global top 20. Note what has to
   happen to the partitioner to make that correct with more than one reducer.
2. **Skew.** Feed it a corpus where one word is 40% of all tokens. Watch one
   reducer take far longer, then check whether a combiner fixes it.
3. **Drop the combiner.** Compare `Reduce input records` in the counters with and
   without it. The difference is the network traffic the combiner saved.
4. **Block size.** Re-run with `dfs.blocksize=1048576` and compare map task
   counts. One split per block is not a coincidence.
