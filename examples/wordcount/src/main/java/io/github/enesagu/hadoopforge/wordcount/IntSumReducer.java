package io.github.enesagu.hadoopforge.wordcount;

import java.io.IOException;

import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Reducer;

/**
 * Sums the counts for one word.
 *
 * <p>This class is used twice: as the reducer, and as the job's combiner. That
 * is only legal because summation is associative and commutative — the framework
 * decides freely whether to run a combiner, how many times, and on which
 * subsets, so a combiner whose result depends on seeing all values (an average,
 * for instance) silently produces wrong answers.
 */
public class IntSumReducer extends Reducer<Text, IntWritable, Text, IntWritable> {

    enum Counter {
        UNIQUE_WORDS,
        SINGLETON_WORDS
    }

    // Reused across calls for the same reason as in the mapper.
    private final IntWritable result = new IntWritable();

    @Override
    protected void reduce(Text word, Iterable<IntWritable> counts, Context context)
            throws IOException, InterruptedException {

        int sum = 0;
        for (IntWritable count : counts) {
            // Note: the Iterable yields the SAME IntWritable instance with a new
            // value each iteration. Storing these references in a collection is a
            // classic MapReduce bug — you end up with n copies of the last value.
            sum += count.get();
        }

        context.getCounter(Counter.UNIQUE_WORDS).increment(1);
        if (sum == 1) {
            // A high singleton ratio usually means the tokenizer is letting
            // punctuation or markup through.
            context.getCounter(Counter.SINGLETON_WORDS).increment(1);
        }

        result.set(sum);
        context.write(word, result);
    }
}
