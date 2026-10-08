// Exits 0 when the URL answers 200 over TLS the JDK trusts.
public class Fetch {
  public static void main(String[] args) throws Exception {
    var client = java.net.http.HttpClient.newHttpClient();
    var request = java.net.http.HttpRequest.newBuilder(java.net.URI.create(args[0])).build();
    var response = client.send(request, java.net.http.HttpResponse.BodyHandlers.discarding());
    System.exit(response.statusCode() == 200 ? 0 : 1);
  }
}
