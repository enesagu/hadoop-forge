package io.github.enesagu.hadoopforge.wordcount;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.conf.Configured;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Job;
import org.apache.hadoop.mapreduce.lib.input.FileInputFormat;
import org.apache.hadoop.mapreduce.lib.output.FileOutputFormat;
import org.apache.hadoop.util.Tool;
import org.apache.hadoop.util.ToolRunner;

/**
 * Driver for the WordCount job.
 *
 * <pre>
 *   hadoop jar wordcount-1.0.0.jar /input /output
 *   hadoop jar wordcount-1.0.0.jar -D mapreduce.job.reduces=4 /input /output
 * </pre>
 *
 * <p>Implementing {@link Tool} and launching through {@link ToolRunner} is not
 * boilerplate: it is what makes {@code -D}, {@code -files}, {@code -libjars} and
 * {@code -archives} work. A driver with a plain {@code main} silently ignores
 * every one of them, and the resulting "my -D had no effect" confusion is a rite
 * of passage nobody needs.
 */
public class WordCount extends Configured implements Tool {

    private static final String OUTPUT_OVERWRITE = "wordcount.output.overwrite";

    @Override
    public int run(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("Usage: WordCount [generic options] <input> <output>");
            System.err.println();
            System.err.println("Job options (pass with -D key=value):");
            System.err.printf("  %-34s fold to lower case (default true)%n",
                    TokenizerMapper.CASE_INSENSITIVE);
            System.err.printf("  %-34s drop shorter tokens (default 1)%n",
                    TokenizerMapper.MIN_LENGTH);
            System.err.printf("  %-34s delete the output directory first (default false)%n",
                    OUTPUT_OVERWRITE);
            System.err.printf("  %-34s number of reducers (default 1)%n",
                    "mapreduce.job.reduces");
            ToolRunner.printGenericCommandUsage(System.err);
            return 2;
        }

        Configuration conf = getConf();
        Path input = new Path(args[0]);
        Path output = new Path(args[1]);

        // MapReduce refuses to start if the output directory exists. That is a
        // feature — it stops a re-run from silently half-overwriting results —
        // so removal has to be asked for explicitly.
        FileSystem fs = output.getFileSystem(conf);
        if (fs.exists(output)) {
            if (conf.getBoolean(OUTPUT_OVERWRITE, false)) {
                System.err.println("Deleting existing output directory: " + output);
                fs.delete(output, true);
            } else {
                System.err.println("Output directory already exists: " + output);
                System.err.println("Remove it, or pass -D " + OUTPUT_OVERWRITE + "=true");
                return 1;
            }
        }

        Job job = Job.getInstance(conf, "hadoop-forge wordcount");

        // Tells YARN which jar to ship to every container. Without it the job
        // fails on the cluster with ClassNotFoundException while working fine
        // locally, because the local classpath happened to have the classes.
        job.setJarByClass(WordCount.class);

        job.setMapperClass(TokenizerMapper.class);
        job.setReducerClass(IntSumReducer.class);

        // Safe here because sum is associative and commutative. See IntSumReducer.
        job.setCombinerClass(IntSumReducer.class);

        job.setOutputKeyClass(Text.class);
        job.setOutputValueClass(IntWritable.class);

        FileInputFormat.addInputPath(job, input);
        FileOutputFormat.setOutputPath(job, output);

        // Recurse into subdirectories rather than failing on the first one found.
        FileInputFormat.setInputDirRecursive(job, true);

        boolean succeeded = job.waitForCompletion(true);
        if (succeeded) {
            System.out.printf("%nCounters:%n");
            System.out.printf("  lines read      %d%n",
                    job.getCounters().findCounter(TokenizerMapper.Counter.LINES_READ).getValue());
            System.out.printf("  tokens emitted  %d%n",
                    job.getCounters().findCounter(TokenizerMapper.Counter.TOKENS_EMITTED).getValue());
            System.out.printf("  unique words    %d%n",
                    job.getCounters().findCounter(IntSumReducer.Counter.UNIQUE_WORDS).getValue());
            System.out.printf("  singletons      %d%n",
                    job.getCounters().findCounter(IntSumReducer.Counter.SINGLETON_WORDS).getValue());
        }
        return succeeded ? 0 : 1;
    }

    public static void main(String[] args) throws Exception {
        int exitCode = ToolRunner.run(new Configuration(), new WordCount(), args);
        System.exit(exitCode);
    }
}
