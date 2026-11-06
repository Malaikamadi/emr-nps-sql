package sl.gov.mohs.connector.config;

import java.net.InetAddress;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.boot.web.servlet.server.ConfigurableServletWebServerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;

@Configuration
public class LocalServerConfig {
    @Bean
    @Order(Ordered.LOWEST_PRECEDENCE)
    WebServerFactoryCustomizer<ConfigurableServletWebServerFactory> loopbackOnly() {
        return factory -> factory.setAddress(InetAddress.getLoopbackAddress());
    }
}
