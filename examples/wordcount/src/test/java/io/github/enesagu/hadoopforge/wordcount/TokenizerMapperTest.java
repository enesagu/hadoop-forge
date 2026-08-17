package io.github.enesagu.hadoopforge.wordcount;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.LongWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Counter;
import org.apache.hadoop.mapreduce.Mapper;
import org.apache.hadoop.mapreduce.counters.GenericCounter;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.invocation.InvocationOnMock;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class TokenizerMapperTest {

    private TokenizerMapper mapper;
    private Mapper<LongWritable, Text, Text, IntWritable>.Context context;
    private Configuration conf;
    private List<String> emitted;
    private Map<String, Counter> counters;

    @SuppressWarnings("unchecked")
    @BeforeEach
    void setUp() throws Exception {
        mapper = new TokenizerMapper();
        conf = new Configuration();
        emitted = new ArrayList<>();
        counters = new HashMap<>();

        context = mock(Mapper.Context.class);
        when(context.getConfiguration()).thenReturn(conf);

        // Counters are asked for by enum; hand back a real, independent counter
        // per name so increments accumulate the way they do on a cluster.
        when(context.getCounter(any(Enum.class))).thenAnswer((InvocationOnMock inv) -> {
            Enum<?> key = inv.getArgument(0);
            return counters.computeIfAbsent(key.name(),
                    name -> new GenericCounter(name, name));
        });

        // Text is mutable and the mapper reuses one instance, so the value must
        // be copied at write time — exactly as the real framework serialises it.
        doAnswer(inv -> {
            emitted.add(inv.getArgument(0).toString());
            assertEquals(1, ((IntWritable) inv.getArgument(1)).get(),
                    "the mapper must always emit a count of one");
            return null;
        }).when(context).write(any(Text.class), any(IntWritable.class));
    }

    private void map(String line) throws Exception {
        mapper.setup(context);
        mapper.map(new LongWritable(0), new Text(line), context);
    }

    private long counter(Enum<?> key) {
        return counters.get(key.name()).getValue();
    }

    @Test
    @DisplayName("splits a line into lower-cased tokens")
    void tokenizesAndLowerCases() throws Exception {
        map("The quick brown Fox");
        assertEquals(List.of("the", "quick", "brown", "fox"), emitted);
        assertEquals(4, counter(TokenizerMapper.Counter.TOKENS_EMITTED));
        assertEquals(1, counter(TokenizerMapper.Counter.LINES_READ));
    }

    @Test
    @DisplayName("treats punctuation as a delimiter but keeps internal apostrophes")
    void handlesPunctuation() throws Exception {
        map("Don't stop -- believing, ever!");
        assertEquals(List.of("don't", "stop", "believing", "ever"), emitted);
    }

    @Test
    @DisplayName("strips apostrophes used as quotes")
    void stripsSurroundingApostrophes() throws Exception {
        map("'quoted' word");
        assertEquals(List.of("quoted", "word"), emitted);
    }

    @Test
    @DisplayName("counts blank lines separately and emits nothing for them")
    void countsEmptyLines() throws Exception {
        map("   ");
        assertTrue(emitted.isEmpty());
        assertEquals(1, counter(TokenizerMapper.Counter.EMPTY_LINES));
    }

    @Test
    @DisplayName("honours the case-sensitivity switch")
    void respectsCaseSensitiveMode() throws Exception {
        conf.setBoolean(TokenizerMapper.CASE_INSENSITIVE, false);
        map("Apple apple");
        assertEquals(List.of("Apple", "apple"), emitted);
    }

    @Test
    @DisplayName("drops tokens below the minimum length and counts the rejects")
    void enforcesMinimumTokenLength() throws Exception {
        conf.setInt(TokenizerMapper.MIN_LENGTH, 4);
        map("a bc def ghij");
        assertEquals(List.of("ghij"), emitted);
        assertEquals(3, counter(TokenizerMapper.Counter.TOKENS_REJECTED));
    }

    @Test
    @DisplayName("keeps digits and non-Latin letters")
    void keepsDigitsAndUnicode()
            throws Exception {
        map("veri 2024 çalışma ağı");
        assertEquals(List.of("veri", "2024", "çalışma", "ağı"), emitted);
    }
}
