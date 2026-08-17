package io.github.enesagu.hadoopforge.wordcount;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Counter;
import org.apache.hadoop.mapreduce.Reducer;
import org.apache.hadoop.mapreduce.counters.GenericCounter;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class IntSumReducerTest {

    private IntSumReducer reducer;
    private Reducer<Text, IntWritable, Text, IntWritable>.Context context;
    private final Map<String, Integer> results = new HashMap<>();
    private final Map<String, Counter> counters = new HashMap<>();

    @SuppressWarnings("unchecked")
    @BeforeEach
    void setUp() throws Exception {
        reducer = new IntSumReducer();
        context = mock(Reducer.Context.class);

        when(context.getCounter(any(Enum.class))).thenAnswer(inv -> {
            Enum<?> key = inv.getArgument(0);
            return counters.computeIfAbsent(key.name(), n -> new GenericCounter(n, n));
        });

        doAnswer(inv -> {
            results.put(inv.getArgument(0).toString(),
                        ((IntWritable) inv.getArgument(1)).get());
            return null;
        }).when(context).write(any(Text.class), any(IntWritable.class));
    }

    private void reduce(String word, int... values) throws Exception {
        List<IntWritable> iterable = new ArrayList<>(values.length);
        for (int v : values) {
            iterable.add(new IntWritable(v));
        }
        reducer.reduce(new Text(word), iterable, context);
    }

    @Test
    @DisplayName("sums all counts for a key")
    void sumsCounts() throws Exception {
        reduce("hadoop", 1, 1, 1, 1, 1);
        assertEquals(5, results.get("hadoop"));
    }

    @Test
    @DisplayName("works on pre-aggregated input, which is what makes it a valid combiner")
    void isAssociative() throws Exception {
        // A combiner may have already collapsed (1,1,1) into 3 upstream. Summing
        // partial sums must give the same answer as summing the originals.
        reduce("hdfs", 3, 2, 1);
        assertEquals(6, results.get("hdfs"));
    }

    @Test
    @DisplayName("counts unique and singleton words")
    void tracksCounters() throws Exception {
        reduce("yarn", 1);
        reduce("mapreduce", 4);
        assertEquals(2, counters.get(IntSumReducer.Counter.UNIQUE_WORDS.name()).getValue());
        assertEquals(1, counters.get(IntSumReducer.Counter.SINGLETON_WORDS.name()).getValue());
    }

    @Test
    @DisplayName("emits zero rather than failing on an empty value list")
    void handlesEmptyValues() throws Exception {
        reduce("orphan");
        assertEquals(0, results.get("orphan"));
    }
}
