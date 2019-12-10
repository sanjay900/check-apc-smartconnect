#! /usr/bin/perl -w
use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request::Common;
use HTTP::Cookies;
use JSON;
use Try::Tiny;

my $id = shift;
my $username = shift;
my $password = shift;
# Store all cookies, we need them for auth. Cache them in a file, that way, we can reuse them across sessions
my $jar = HTTP::Cookies->new( 
    file => "/tmp/apc-cookies-$id.txt",
    autosave => 1,
    ignore_discard => 1,
);
# Create an agent that we can for web requests
my $ua = LWP::UserAgent->new(cookie_jar => $jar);
# Try and fetch UPS data
my $res = $ua->request(GET "https://smartconnect.apc.com/api/v1/gateways/$id");
my $ups_core_data;
# Using a try catch here means that json errors are also treated as if we did not log in successfully
try {
    $ups_core_data = decode_json($res->decoded_content);
    # If error is defined, than we don't have permission and need to log in.
    if (defined $ups_core_data->{'error'}) {
        die $ups_core_data->{'error'};
    }
} catch {
    # Navigate to login page
    $res = $ua->request(GET 'https://smartconnect.apc.com/auth/login');
    # The login page sets a bunch of cookies using javascript. Fake that using a regex.
    my $str = $res->decoded_content;
    while($str =~ /document.cookie\s*=\s+"([^"]+)=([^"]+);Path=(.);(secure)?";/g) {
        $jar->set_cookie(0, $1, $2, $3, "secureidentity.schneider-electric.com");
    }
    # The login page then redirects using javascript. Fake that using a regex.
    my @redir = $res->decoded_content =~ /window.location\s*=\s+"([^"]+)";/g;
    $res = $ua->request(GET "https://secureidentity.schneider-electric.com/@redir");

    # Construct a form that we can submit for login
    my %data = (
        'AJAXREQUEST' => '_viewRoot',
        'usrname' => $username,
        'password' => $password,
        'com.salesforce.visualforce.ViewStateMAC' => $res->decoded_content =~ /"com.salesforce.visualforce.ViewStateMAC"\s+value="([^"]+)"/g,
        'com.salesforce.visualforce.ViewStateVersion' => $res->decoded_content =~ /"com.salesforce.visualforce.ViewStateVersion"\s+value="([^"]+)"/g,
        'com.salesforce.visualforce.ViewState' => $res->decoded_content =~ /"com.salesforce.visualforce.ViewState"\s+value="([^"]+)"/g,
    );
    
    # Some extra fields are appended to the form on submit. We can easily find them using a regex, and append them
    # Without these, a login will not be successful.
    my @jid=$res->decoded_content =~ /userloginInJavascript.*((j_id0:j_id\d+):j_id\d+)/g;
    foreach(@jid) {
        $data{$_} = $_;
    }
    # Submit that form
    $res = $ua->request(POST 'https://secureidentity.schneider-electric.com/identity/UserLogin', [ %data ]);

    # UserLogin returns a weird client based redirect, so we need to act on it manually
    @redir = $res->decoded_content =~ /<meta\s+name="Location"\s+content="([^"]+)" \/>/g;
    $res = $ua->request(GET @redir);

    # Then that page uses javascript to redirect, so we need to follow that manually with a regex
    @redir = $res->decoded_content =~ /window.location.href\s*='([^']+)';/g;

    # Then that page uses javascript to redirect, so we need to follow that manually with a regex
    $res = $ua->request(GET "https://secureidentity.schneider-electric.com/@redir");
    @redir = $res->decoded_content =~ /window.location.href\s*='([^']+)';/g;
    $res = $ua->request(GET @redir);
    # And now, finally, we can request information about a ups
    $res = $ua->request(GET "https://smartconnect.apc.com/api/v1/gateways/$id");
    $ups_core_data = decode_json($res->decoded_content);
};
# And information about
$res = $ua->request(GET "https://smartconnect.apc.com/api/v1/gateways/$id?collection=input,output,battery,network");
my $ups_other_data = decode_json($res->decoded_content);
my $mode = $ups_core_data->{'status'}{'upsOperatingMode'};
my $runtime = $ups_other_data->{'battery'}{'runtimeRemaining'};
my $load = $ups_other_data->{'output'}{'loadRealPercentage'};
my $temp = $ups_other_data->{'battery'}{'temperature'};
my $charge = $ups_other_data->{'battery'}{'chargeStatePercentage'};
my $status = "- LOAD $load\% - TEMP ${temp}C - BAT $charge\% - RUNTIME $runtime | 'load'=${load}\%;;;; 'temp'=${temp};;;; 'runtime'=${runtime}s;;;; 'charge'=${charge}\%";

if ($mode eq "online") {
    print "OK $status\n";
    exit(0);
} elsif ($mode eq "onbattery.rtc") {
    print "OK - UPS On Battery for Calibration - $status";
    exit(0);
} elsif ($mode eq "bypass_ups_init") {
    print "WARNING - UPS Power Bypass, UPS Initiated - $status";
    exit(1);
} elsif ($mode eq "bypass_user_init") {
    print "WARNING - UPS Power Bypass, User Initiated - $status";
    exit(1);
} elsif ($mode eq "onbattery") {
    print "WARNING - UPS On Battery - $status";
    exit(1);
} elsif ($mode eq "onbattery.low_battery") {
    print "WARNING - UPS Low Battery - $status";
    exit(1);
} elsif ($mode eq "ups_off") {
    print "WARNING - UPS Output Power Turned Off - $status";
    exit(1);
} else {
    print "CRITICAL - UPS Offline";
    exit(2);
}
