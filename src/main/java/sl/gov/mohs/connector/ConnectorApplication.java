package sl.gov.mohs.connector;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import sl.gov.mohs.connector.config.Dhis2Properties;

@SpringBootApplication
@EnableConfigurationProperties(Dhis2Properties.class)
public class ConnectorApplication {
    public static void main(String[] args) {
        SpringApplication.run(ConnectorApplication.class, args);
    }
}
