package io.github.enesagu.hadoopforge.wordcount;

import java.io.IOException;
import java.text.Normalizer;
import java.util.regex.Pattern;

import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.LongWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Mapper;

/**
 * Emits {@code (word, 1)} for every token on a line.
 *
 * <p>The input key is the byte offset of the line within its split, supplied by
 * {@code TextInputFormat}; it is unused here, which is typical.
 */
public class TokenizerMapper extends Mapper<LongWritable, Text, Text, IntWritable> {

    /** Counter group visible in the job summary and the ResourceManager UI. */
    enum Counter {
        LINES_READ,
        TOKENS_EMITTED,
        EMPTY_LINES,
        TOKENS_REJECTED
    }

    /** Configuration key: fold everything to lower case before counting. */
    static final String CASE_INSENSITIVE = "wordcount.case.insensitive";

    /** Configuration key: drop tokens shorter than this. */
    static final String MIN_LENGTH = "wordcount.min.token.length";

    // Split on anything that is not a letter, digit or apostrophe, so "don't"
    // stays one token while "end. Start" becomes two.
    private static final Pattern DELIMITER = Pattern.compile("[^\\p{L}\\p{N}']+");

    // Allocated once and reused for every emission. A map task runs this method
    // millions of times; allocating a Text and an IntWritable per token is the
    // single most common source of avoidable GC pressure in MapReduce code.
    private final Text outputKey = new Text();
    private static final IntWritable ONE = new IntWritable(1);

    private boolean caseInsensitive;
    private int minLength;

    @Override
    protected void setup(Context context) {
        this.caseInsensitive = context.getConfiguration().getBoolean(CASE_INSENSITIVE, true);
        this.minLength = context.getConfiguration().getInt(MIN_LENGTH, 1);
    }

    @Override
    protected void map(LongWritable offset, Text line, Context context)
            throws IOException, InterruptedException {

        context.getCounter(Counter.LINES_READ).increment(1);

        String text = line.toString().trim();
        if (text.isEmpty()) {
            context.getCounter(Counter.EMPTY_LINES).increment(1);
            return;
        }

        if (caseInsensitive) {
            text = text.toLowerCase();
        }

        // Decompose accents so "café" and "cafe" are not counted as different
        // words purely because of Unicode normal form.
        text = Normalizer.normalize(text, Normalizer.Form.NFC);

        for (String token : DELIMITER.split(text)) {
            // Leading and trailing apostrophes are punctuation, not part of the
            // word: 'quoted' should count as quoted.
            token = trimApostrophes(token);

            if (token.length() < minLength) {
                if (!token.isEmpty()) {
                    context.getCounter(Counter.TOKENS_REJECTED).increment(1);
                }
                continue;
            }

            outputKey.set(token);
            context.write(outputKey, ONE);
            context.getCounter(Counter.TOKENS_EMITTED).increment(1);
        }
    }

    private static String trimApostrophes(String token) {
        int start = 0;
        int end = token.length();
        while (start < end && token.charAt(start) == '\'') {
            start++;
        }
        while (end > start && token.charAt(end - 1) == '\'') {
            end--;
        }
        return token.substring(start, end);
    }
}
