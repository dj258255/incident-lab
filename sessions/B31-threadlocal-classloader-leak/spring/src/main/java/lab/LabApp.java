package lab;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.boot.web.servlet.support.SpringBootServletInitializer;
import org.springframework.context.annotation.Bean;

/**
 * WAR로 패키징해 외부 Tomcat 10.1에 올린다. 내장 톰캣이 아니라 실제 컨테이너에 배포해야
 * 재배포(언디플로이) 때 Tomcat이 무엇을 하는지 볼 수 있다.
 */
@SpringBootApplication
public class LabApp extends SpringBootServletInitializer {

    @Override
    protected SpringApplicationBuilder configure(SpringApplicationBuilder builder) {
        return builder.sources(LabApp.class);
    }

    public static void main(String[] args) {
        SpringApplication.run(LabApp.class, args);
    }

    @Bean
    public FilterRegistrationBean<ContextFilters.Leaky> leakyFilter() {
        FilterRegistrationBean<ContextFilters.Leaky> reg = new FilterRegistrationBean<>(new ContextFilters.Leaky());
        reg.addUrlPatterns("/api/leaky/*");
        reg.setOrder(1);
        return reg;
    }

    @Bean
    public FilterRegistrationBean<ContextFilters.Safe> safeFilter() {
        FilterRegistrationBean<ContextFilters.Safe> reg = new FilterRegistrationBean<>(new ContextFilters.Safe());
        reg.addUrlPatterns("/api/safe/*");
        reg.setOrder(1);
        return reg;
    }
}
