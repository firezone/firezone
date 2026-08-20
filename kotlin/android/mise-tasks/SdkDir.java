import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

/** Prints the `sdk.dir` property of the properties file passed as the first argument. */
public class SdkDir {
    public static void main(String[] args) throws Exception {
        Properties properties = new Properties();
        try (InputStream in = Files.newInputStream(Path.of(args[0]))) {
            properties.load(in);
        }
        System.out.println(properties.getProperty("sdk.dir", ""));
    }
}
