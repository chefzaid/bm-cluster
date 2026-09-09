import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.handler.codec.http.*;
import io.netty.handler.codec.http.cors.*;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.baggage.propagation.W3CBaggagePropagator;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.propagation.TextMapGetter;
import java.util.*;

public class KeycloakLibraryTest {
  public static void main(String[] args) throws Exception {
    var channel = new EmbeddedChannel(new CorsHandler(CorsConfigBuilder.forOrigin("https://example.invalid").build()));
    var request = new DefaultFullHttpRequest(HttpVersion.HTTP_1_1, HttpMethod.GET, "/");
    request.headers().set(HttpHeaderNames.ORIGIN, "https://example.invalid");
    channel.writeInbound(request);
    ((FullHttpRequest)channel.readInbound()).release();
    var response = new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, HttpResponseStatus.OK);
    response.headers().set(HttpHeaderNames.VARY, "Authorization, Cookie");
    channel.writeOutbound(response);
    FullHttpResponse received = channel.readOutbound();
    var vary = String.join(",", received.headers().getAll(HttpHeaderNames.VARY)).toLowerCase(Locale.ROOT);
    if (!(vary.contains("authorization") && vary.contains("cookie") && vary.contains("origin")))
      throw new AssertionError("CORS overwrote existing cache controls: " + vary);
    received.release(); channel.finishAndReleaseAll();
    var getter = new TextMapGetter<Map<String, String>>() {
      public Iterable<String> keys(Map<String, String> carrier) {return carrier.keySet();}
      public String get(Map<String, String> carrier, String key) {return carrier.get(key);}
    };
    var propagator = W3CBaggagePropagator.getInstance();
    var normal = propagator.extract(Context.root(), Map.of("baggage", "fixture=value"), getter);
    if (!"value".equals(Baggage.fromContext(normal).getEntryValue("fixture"))) throw new AssertionError("Valid baggage lost");
    var oversized = propagator.extract(Context.root(), Map.of("baggage", "huge=" + "x".repeat(9000)), getter);
    if (Baggage.fromContext(oversized).size() != 0) throw new AssertionError("Oversized baggage accepted");
    var entries = new StringJoiner(",");
    for (int i=0; i<100; i++) entries.add("key" + i + "=value");
    var many = propagator.extract(Context.root(), Map.of("baggage", entries.toString()), getter);
    if (Baggage.fromContext(many).size() != 64) throw new AssertionError("Baggage entry limit missing");
    var driver = new com.microsoft.sqlserver.jdbc.SQLServerDriver();
    if (driver.getMajorVersion() != 13 || driver.getMinorVersion() != 4) throw new AssertionError("Unexpected JDBC driver");
    System.out.println("CORS cache controls, baggage limits and JDBC driver checks passed");
  }
}
