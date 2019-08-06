# Default Varnish cache policy for Varnish Purge.
# Drupal 8 cache tag support inspired by https://gitlab.wklive.net/snippets/32

# This configuration file supports the following PURGE and BAN requests:

#  - PURGE accepts a URL or a URL with a regular expression in the path.
#    $ curl 'http://HOSTNAME-OR-IP-OF-VARNISH/videos' -X PURGE
#    $ curl 'http://HOSTNAME-OR-IP-OF-VARNISH/'.*projects.*' -X PURGE
#
#  - BAN accepts a Cache-Tags header containing the pipe-separated cache tags to
#    ban.
#    $ curl 'http://HOSTNAME-OR-IP-OF-VARNISH/' -X BAN -H 'Cache-Tags: node_list'
#    $ curl 'http://HOSTNAME-OR-IP-OF-VARNISH/' -X BAN -H 'Cache-Tags: media:3918|media_list'
#
# It is assumed this configuration is used with the varnish_purge Drupal
# module. Most sites will want three purging configurations; one to purge tags
# using the "Varnish bundled" purger, one to purge individual paths, and one to
# act as the "everything" purge (which is just a path with the .* regex).

vcl 4.0;

# include "/etc/varnish/backends.vcl";

backend drupal {
    .host = "127.0.0.1";
    .port = "80";
    .max_connections = 300; # That's it
#     .probe = {
#         .request =
#             "HEAD /healthcheck.php HTTP/1.1"
#             "Host: www.example.com"
#             "Connection: close";
#         .interval = 5s; # check the health of each backend every 5 seconds
#         .timeout = 10s; # A high timeout because we test an uncached Drupal bootstrap
#         .initial = 0; # TODO: Assume all backends are healthy on varnish startup - but this doesn't actually work.
#         .window = 5;
#         .threshold = 3;
#         }
    .first_byte_timeout     = 300s;   # How long to wait before we receive a first byte from our backend?
    .connect_timeout        = 30s;     # How long to wait for a backend connection?
    .between_bytes_timeout  = 30s;     # How long to wait between bytes received from our backend?
}

import directors;
sub vcl_init {
    new drupalhosts = directors.round_robin();
    drupalhosts.add_backend(drupal);
}

# Incoming requests: Decide whether to try cache or not
sub vcl_recv {
  set req.backend_hint = drupalhosts.backend();

  # Pipe all requests for files whose Content-Length is >=10,000,000. See
  # comment in vcl_backend_fetch.
  if (req.http.x-pipe && req.restarts > 0) {
    return(pipe);
  }

  # Only allow BAN requests from IP addresses in the 'purge' ACL.
  if (req.method == "BAN") {
    # Check against the ACLs.
    #  if (!client.ip ~ purge) {
    #    return (synth(403, "Not allowed."));
    #  }

    # Logic for the ban, using the Cache-Tags header. For more info
    # see https://github.com/geerlingguy/drupal-vm/issues/397.
    # Note the above issue shows a comma-delimited list for tags, when they
    # must be pipe-separated.
    if (req.http.Cache-Tags) {
      ban("obj.http.Cache-Tags ~ " + req.http.Cache-Tags);
    }
    else {
      return (synth(403, "Cache-Tags header missing."));
    }

    # Throw a synthetic page so the request won't go to the backend.
    return (synth(200, "Ban added."));
  }

  # don't cache healthchecks
  if (req.url ~ "healthcheck") {
    return(pipe);
  }

  # Grace: Avoid thundering herd when an object expires by serving
  # expired stale object during the next N seconds while one request
  # is made to the backend for that object.
  set req.grace = 120s;

  # EXAMPLE: How to do an external redirect in Varnish
  # in case we need to redirect a site to another balancer.
  # if (req.http.host ~ "^(www.)?francesoir.fr$") {
  #  error 302;
  # }

  # PURGE method support: PURGE request must include
  # a X-Nbcu-Purge header which is weak but better
  # than nothing or ip address whack-a-mole. Example:
  # curl -X PURGE -H "X-Nbcu-Purge: sitename" http://site/file
  # TODO: This should be done by allowing PURGE from any backend host.
  if (req.method == "PURGE") {
    # We use obj.http instead of req.http so this is "bun lurker" friendly.
    # https://varnish-cache.org/docs/trunk/users-guide/purging.html
    # ban("obj.http.url ~ " + req.url);
    # TODO: However, this isn't working for me. Use the less performant option
    # as we expect most cache operations to be by cache tags.
    ban("req.url ~ " + req.url);
    return (synth(200, "Ban added for " + req.url));
  }

  # Don't Cache executables or archives
  # This was put in place to ensure these objects are piped rather then passed to the backend.
  # We had a customer who had a 500+MB file *.msi that Varnish was choking on,
  # so we decided to pipe all archives and executables to keep them from choking Varnish.
  if (req.url ~ "\.(msi|exe|dmg|zip|tgz|gz)") {
    return(pipe);
  }

  # Don't check cache for POSTs and various other HTTP request types
  if (req.method != "GET" && req.method != "HEAD") {
    return(pass);
  }

  # Find out if the request is pinned to a specific device and store it for later.
  if (req.http.Cookie ~ "desktop") {
    set req.http.X-pinned-device = "desktop";
  }
  else if (req.http.Cookie ~ "mobile") {
    set req.http.X-pinned-device = "mobile";
  }
  else if (req.http.Cookie ~ "tablet") {
    set req.http.X-pinned-device = "tablet";
  }

  # Always cache the following file types for all users if not coming from the private file system.
  if (req.url ~ "(?i)/(modules|themes|files)/.*\.(png|gif|jpeg|jpg|ico|swf|css|js|flv|f4v|mov|mp3|mp4|pdf|doc|ttf|eot|svg|woff|eof|ppt)(\?[a-z0-9]+)?$" && req.url !~ "/system/files") {
    unset req.http.Cookie;
    # Set header so we know to remove Set-Cookie later on.
    set req.http.X-static-asset = "True";
  }

  # Don't check cache for cron.php
  if (req.url ~ "^/cron.php") {
    return(pass);
  }

  # This is part of Varnish's default behavior to pass through any request that
  # comes from an http auth'd user.
  if (req.http.Authorization) {
    return(pass);
  }

  # Remove all cookies that Drupal doesn't need to know about. ANY remaining
  # cookie will cause the request to pass-through to Apache. For the most part
  # we always set the NO_CACHE cookie after any POST request, disabling the
  # Varnish cache temporarily. The session cookie allows all authenticated users
  # to pass through as long as they're logged in.
  if (req.http.Cookie) {
    set req.http.Cookie = ";" + req.http.Cookie;
    set req.http.Cookie = regsuball(req.http.Cookie, "; +", ";");
    set req.http.Cookie = regsuball(req.http.Cookie, ";(S?SESS[a-z0-9]+|NO_CACHE)=", "; \1=");
    set req.http.Cookie = regsuball(req.http.Cookie, ";[^ ][^;]*", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");

    if (req.http.Cookie == "") {
      # If there are no remaining cookies, remove the cookie header. If there
      # aren't any cookie headers, Varnish's default behavior will be to cache
      # the page.
      unset req.http.Cookie;
    }
    else {
      # If there are any cookies left (a session or NO_CACHE cookie), do not
      # cache the page. Pass it on to Apache directly.
      return (pass);
    }
  }

  # x-forward-for
  if (req.http.x-forwarded-for) {
    set req.http.X-Forwarded-For = req.http.X-Forwarded-For;
  } else {
    set req.http.X-Forwarded-For = client.ip;
  }

  # Default cache check
  return(hash);
}


# Cache miss: request is about to be sent to the backend
sub vcl_miss {
  # PURGE method support
  if (req.method == "PURGE") {
    return (synth(404, "Not in cache."));
  }
}

# Pass (including HitPass): request is about to be sent to the backend
# or about to be delivered
sub vcl_pass {
}

# Piped requests should not support keepalive because
# Varnish won't have chance to process or log the subrequests
sub vcl_pipe {
  set req.http.connection = "close";
}

# sub vcl_backend_fetch {
  # Pipe all requests for files whose Content-Length is >=10,000,000. See
  # comment in vcl_pipe.
  # TODO: Need to find a Varnish 4+ technique.
  # if ( beresp.http.Content-Length ~ "[0-9]{8,}" ) {
  #    set req.http.x-pipe = "1";
  #    return(retry);
  # }
# }

# Backend response: Determine whether to cache each backend response
sub vcl_backend_response {
  # Set ban-lurker friendly custom headers.
  set beresp.http.X-Url = bereq.url;
  set beresp.http.X-Host = bereq.http.host;

  # Allow items to remain in cache up to 6 hours past their cache expiration.
  set beresp.grace = 6h;

  # Remove the Set-Cookie header from static assets
  # This is just for cleanliness and is also done in vcl_deliver
  if (bereq.http.X-static-asset) {
    unset beresp.http.Set-Cookie;
  }

  # Don't cache responses with status codes greater than 302 or
  # HEAD and POST requests.
  if (beresp.status >= 302 || !(beresp.ttl > 0s) || bereq.method != "GET") {
    call varnish_pass;
  }

  # Make sure we are caching 301s for at least 15 mins.
  if (beresp.status == 301) {
    if (beresp.ttl < 15m) {
      set beresp.ttl = 15m;
    }
  }

  # Respect explicit no-cache headers
  if (beresp.http.Pragma ~ "no-cache" ||
     beresp.http.Cache-Control ~ "no-cache" ||
     beresp.http.Cache-Control ~ "private") {
    call varnish_pass;
  }

  # Don't cache cron.php
  if (bereq.url ~ "^/cron.php") {
    set beresp.uncacheable = true;
    set beresp.ttl = 120s;
    return (deliver);
  }

  # Don't cache if Drupal session cookie is set
  # Note: Pressflow doesn't send SESS cookies to anon users
  if (beresp.http.Set-Cookie ~ "(^|;\s*)(S?SESS[a-zA-Z0-9]*)=") {
    call varnish_pass;
  }

  # Grace: Avoid thundering herd when an object expires by serving
  # expired stale object during the next N seconds while one request
  # is made to the backend for that object.
  set beresp.grace = 120s;

  # Pass a shorter cache-control header on to the browser compared to the
  # default max-age set in Drupal.
  # @see https://varnish-cache.org/trac/wiki/VCLExampleLongerCaching
  if (beresp.ttl > 0s) {
    # Remove Expires from backend, it's not long enough.
    unset beresp.http.expires;

    # Set the client's TTL on this object.
    set beresp.http.Cache-Control = "public, max-age=900";

    # Marker for vcl_deliver to reset Age:
    set beresp.http.magicmarker = "1";
  }

  # Cache anything else. Returning nothing here would fall-through
  # to Varnish's default cache store policies.
  return(deliver);
}

# Deliver the response to the client
sub vcl_deliver {
  # Invalid session cookies will cause Varnish to pass on the request and by
  # default respect the Drupal cache-control header. Since the session is
  # invalid, Drupal will return the anonymous TTL of 1 year. We need to make
  # sure that Drupal is not returning a cookie (indicating a valid session),
  # and then drop that ttl back down to 15 minutes.
  # Pass a shorter cache-control header on to the browser compared to the
  # default max-age set in Drupal.
  # @see https://varnish-cache.org/trac/wiki/VCLExampleLongerCaching
  # We also avoid acting on responses that are explicitly no-cache responses.
  if (resp.http.Cache-Control !~ "no-cache" && !resp.http.Set-Cookie) {
    # Remove Expires from backend, it's not long enough.
    unset resp.http.expires;

    # Set the client's TTL on this object.
    set resp.http.Cache-Control = "public, max-age=900";
  }

  if (resp.http.magicmarker) {
    # Remove the magic marker.
    unset resp.http.magicmarker;

    # By definition we have a fresh object.
    set resp.http.age = "0";
  }

  # Remove ban-lurker friendly custom headers when delivering to client.
  unset resp.http.X-Url;
  unset resp.http.X-Host;
  # Comment these for easier Drupal cache tag debugging in development.
  unset resp.http.Cache-Tags;
  unset resp.http.X-Drupal-Cache-Tags;
  unset resp.http.X-Drupal-Cache-Contexts;

  # Don't show Cache-Tags to the end user and replace with a generic HIT /
  # MISS.
  if (obj.hits > 0) {
    set resp.http.Cache-Tags = "HIT";
  }
  else {
    set resp.http.Cache-Tags = "MISS";
  }

  # Add an X-Cache diagnostic header
  if (obj.hits > 0) {
    set resp.http.X-Cache = "HIT";
    set resp.http.X-Cache-Hits = obj.hits;
    # Don't echo cached Set-Cookie headers
    unset resp.http.Set-Cookie;
  } else {
    set resp.http.X-Cache = "MISS";
  }

  # Strip the age header for Akamai requests
  if (req.http.Via ~ "akamai") {
    set resp.http.X-Age = resp.http.Age;
    unset resp.http.Age;
  }

  # Remove the Set-Cookie header from static assets
  if (req.http.X-static-asset) {
    unset resp.http.Set-Cookie;
  }

  # ELB health checks respect HTTP keep-alives, but require the connection to
  # remain open for 60 seconds. Varnish's default keep-alive idle timeout is
  # 5 seconds, which also happens to be the minimum ELB health check interval.
  # The result is a race condition in which Varnish can close an ELB health
  # check connection just before a health check arrives, causing that check to
  # fail. Solve the problem by not allowing HTTP keep-alive for ELB checks.
  if (req.http.user-agent ~ "ELB-HealthChecker") {
    set resp.http.Connection = "close";
  }
  return(deliver);
}


# Backend down: Error page returned when all backend servers are down
sub vcl_backend_error {
  # EXAMPLE: How to do an external redirect in Varnish
  # in case we need to redirect a site to another balancer.
  return (fail("Service unavailable"));
}

sub vcl_synth {
  # Default Varnish synthesized response for errors or management requests.
  set resp.http.Content-Type = "text/html; charset=utf-8";
      set resp.http.Retry-After = "5";
    synthetic( {"<!DOCTYPE html>
<html>
  <head>
    <title>"} + resp.status + " " + resp.reason + {"</title>
  </head>
  <body>
    <h1>"} + resp.status + " " + resp.reason + {"</h1>
    <p>"} + resp.reason + {"</p>
    <h3>Guru Meditation:</h3>
    <p>XID: "} + req.xid + {"</p>
    <hr>
    <p>Varnish cache server</p>
  </body>
</html>
"});

  return(deliver);
}

sub varnish_pass {
  set beresp.uncacheable = true;
  return (deliver);
}
