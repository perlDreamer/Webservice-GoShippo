use strict;
use warnings;
package WebService::GoShippo;

use HTTP::Thin;
use HTTP::Request::Common qw/GET DELETE PUT POST/;
use HTTP::CookieJar;
use Time::HiRes qw/sleep gettimeofday/;
use JSON;
use URI;
use Ouch;
use Moo;

=head1 NAME

WebService::GoShippo - A simple client to L<Shippo's REST API|https://goshippo.com/docs/intro/>.

=head1 SYNOPSIS

 use WebService::GoShippo;

 my $shippo = WebService::GoShippo->new(token => 'XXXXXXXXXXxxxxxxxxxxxx', version => '2018-08-28');

 my $addresses = $shippo->get('addresses');

=head1 DESCRIPTION

A light-weight wrapper for Shippo's RESTful API (an example of which can be found at: L<https://goshippo.com/docs/reference>). This wrapper basically hides the request cycle from you so that you can get down to the business of using the API. It doesn't attempt to manage the data structures or objects the web service interfaces with.

The module takes care of all of these things for you:

=over 4

=item Adding authentication headers

C<WebService::GoShippo> adds an authentication header of the type "Authorization: C<$tj-E<gt>token>" to each request.

=item Adding api version number to request header.

C<WebService::GoShippo> can optionally add a header selecting a particular version of the API C< $tj-E<gt>version > to each request you submit.  If you do not request a particular API version,
then Shippo will use the version specified in your account settings.

=item PUT/POST data translated to JSON

When making a request like:

    $tj->post('customers', { customer_id => '27', exemption_type => 'non_exempt', name => 'Andy Dufresne', });

The data in POST request will be translated to JSON using <JSON::to_json> and encoded to UTF8.

=item Response data is deserialized from JSON and returned from each call.

=back

=head1 EXCEPTIONS

All exceptions in C<WebService::GoShippo> are handled by C<Ouch>.  A 500 exception C<"Server returned unparsable content."> is returned if Shippo's server returns something that isn't JSON.  If the request isn't successful, then an exception with the code and response and string will be thrown.

=head1 METHODS

The following methods are available.

=head2 new ( params ) 

Constructor.

=over

=item params

A hash of parameters.

=over

=item token

Your token for accessing Shippo's API.  Required.

=item version

The version of the API that you are using, like '2018-02-08', '2017-08-01', etc.  Optional.  If this is left off, then the version setup in your account will be used.

=cut

=item debug_flag

Just a spare, writable flag so that users of the object should log debug information, since GoShippo will likely ask for request/response pairs when
you're having problems.  Hint hint.

    my $sales_tax = $taxjar->get('taxes', $order_information);
    if ($taxjar->debug_flag) {
        $log->info($taxjar->last_response->request->as_string);
        $log->info($taxjar->last_response->decoded_content);
    }

=cut

has token => (
    is          => 'ro',
    required    => 1,
);

has version => (
    is          => 'ro',
    required    => 0,
);

has debug_flag => (
    is          => 'rw',
    required    => 0,
    default     => sub { 0 },
);

=item agent

A LWP::UserAgent compliant object used to keep a persistent cookie_jar across requests.  By default this module uses HTTP::Thin, but you can supply another object when
creating a WebService::GoShippo object.

=back

=back

=cut

has agent => (
    is          => 'ro',
    required    => 0,
    lazy        => 1,
    builder     => '_build_agent',
);

sub _build_agent {
    return HTTP::Thin->new( cookie_jar => HTTP::CookieJar->new() )
}

=head2 last_response

The HTTP::Response object from the last request/reponse pair that was sent, for debugging purposes.

=cut

has last_response => (
    is       => 'rw',
    required => 0,
);

=head2 get(path, params)

Performs a C<GET> request, which is used for reading data from the service.

=over

=item path

The path to the REST interface you wish to call.

=item params

A hash reference of parameters you wish to pass to the web service.  These parameters will be added as query parameters to the URL for you.

=back

=cut

sub get {
    my ($self, $path, $params) = @_;
    my $uri = $self->_create_uri($path);
    $uri->query_form($params);
    my $base_request = GET $uri->as_string;
    $self->_add_headers($base_request);
    return $self->_process_request($base_request);
}

=head2 get_all(path, params)

Performs as many C<GET> requests as needed to fetch all pages of data.

=over

=item path

The path to the REST interface you wish to call.

=item params

A hash reference of parameters you wish to pass to the web service.  These parameters will be added as query parameters to the URL for you.  Returns the original
response hashref, with all the results from every response concatenated in the C<results> key.

=back

=cut

sub get_all {
    my ($self, $path, $params) = @_;
    my $uri = $self->_create_uri($path);
    $uri->query_form($params);
    my $base_request = GET $uri->as_string;
    $self->_add_headers($base_request);
    my $base_response = $self->_process_request($base_request);
    my $get_more = $base_response->{next};
    while (defined($get_more) && $get_more) {
        my $request = GET $get_more;
        $self->_add_headers($request);
        my $response = $self->_process_request($request);
        push @{ $base_response->{results} }, @{ $response->{results} };
        $get_more = $response->{next};
    }
    return $base_response;
}

=head2 poll(path, params, max_delay)

Poll a REST GET endpoint, with exponential retry.  The first wait is 1 second, then 2 seconds, then 4 until a maximum wait time is reached or passed.

=over

=item path

The path to the REST interface you wish to call.

=item params

A hash reference of parameters you wish to pass to the web service.  These parameters will be added as query parameters to the URL for you.  Returns the original
response hashref, with all the results from every response concatenated in the C<results> key.

=item max_wait

The longest you want to wait for polling the endpoint.  Defaults to 70 seconds.

=back

=cut

sub poll {
    my ($self, $path, $params, $max_wait) = @_;
    $max_wait //= 70;
    my $uri = $self->_create_uri($path);
    $uri->query_form($params);
    my $base_request = GET $uri->as_string;
    $self->_add_headers($base_request);
    my $start_time = gettimeofday();
    my $wait_time = 1;
    my $base_response = $self->_process_request($base_request);
    while ($base_response->{status} eq 'QUEUED' || $base_response->{status} eq 'WAITING') {
        sleep $wait_time;
        my $elapsed_time = gettimeofday() - $start_time;
        if ($elapsed_time > $max_wait) {
            ouch 488, "Maximum wait time exceeded.";
        }
        $base_response = $self->_process_request($base_request);
        $wait_time *= 2;
    }
    return $base_response;
}

=head2 delete(path)

Performs a C<DELETE> request, deleting data from the service.

=over

=item path

The path to the REST interface you wish to call.

=item params

A hash reference of parameters you wish to pass to the web service.  These parameters will be added as query parameters to the URL for you.

=back

=cut

sub delete {
    my ($self, $path, $params) = @_;
    my $uri = $self->_create_uri($path);
    $uri->query_form($params);
    my $base_request = DELETE $uri->as_string;
    $self->_add_headers($base_request);
    return $self->_process_request( $base_request );
}

=head2 put(path, json)

Performs a C<PUT> request, which is used for updating data in the service.

=over

=item path

The path to the REST interface you wish to call.

=item params

A hash reference of parameters you wish to pass to Shippo.  This will be translated to JSON.

=back

=cut

sub put {
    my ($self, $path, $params) = @_;
    my $uri = $self->_create_uri($path);
    my %headers = ( Content => to_json($params, { utf8 => 1, }), );
    my $base_request = PUT $uri->as_string, %headers;
    $self->_add_headers($base_request);
    return $self->_process_request( $base_request );
}

=head2 post(path, params, options)

Performs a C<POST> request, which is used for creating data in the service.

=over

=item path

The path to the REST interface you wish to call.

=item params

A hash reference of parameters you wish to pass to Shippo.  They will be encoded as JSON.

=back

=head2 Notes

The path you provide as arguments to the request methods C<get, post, put delete> should not have a leading slash.

As of early 2019:

The current version of their API is '2018-02-08'.  There is no default value for the C<version> parameter, so please provide this when creating a WebService::GoShippo object.

Shippo provides a free testing mode for prototyping your code but it is not feature complete.   The test mode is accessed by passing a separate token from your regular production token.  Please visit their website for details as to what works in test mode, and what works.

=cut

sub post {
    my ($self, $path, $params) = @_;
    my $uri = $self->_create_uri($path);
    my %headers = ( Content => to_json($params, { utf8 => 1, }), );
    my $base_request = POST $uri->as_string, %headers;
    $self->_add_headers($base_request);
    my $sleep_duration = 0.50;
    my $response = $self->_process_request( $base_request );
    return $response;
}

sub _create_uri {
    my $self = shift;
    my $path = shift;
    return URI->new(join '/', 'https://api.goshippo.com', $path);
}

sub _add_headers {
    my $self    = shift;
    my $request = shift;
    $request->header( Authorization => 'ShippoToken '.$self->token() );
    $request->header( 'Content-Type' => 'application/json' );
    $request->header( 'Accept-Charset' => 'utf-8' );
    if ($self->version) {
        $request->header( 'Shippo-API-Version' => $self->version );
    }
    return;
}

sub _process_request {
    my $self = shift;
    my $request = shift;
    my $response = $self->agent->request($request);
    $response->request($request);
    $self->last_response($response);
    $self->_process_response($response);
}

sub _process_response {
    my $self = shift;
    my $response = shift;
    my $result = eval { from_json($response->decoded_content, {utf8 => 1, }) }; 
    if ($@) {
        ouch 500, 'Server returned unparsable content.', { error => $@, content => $response->decoded_content };
    }
    elsif ($response->is_success) {
        return $result;
    }
    else {
        ouch $response->code, $response->as_string;
    }
}

=head1 PREREQS

L<HTTP::Thin>
L<Ouch>
L<HTTP::Request::Common>
L<HTTP::CookieJar>
L<JSON>
L<URI>
L<Moo>

=head1 SUPPORT

=over

=item Repository

L<https://github.com/perldreamer/WebService-GoShippo>

=item Bug Reports

L<https://github.com/perldreamer/WebService-GoShippo/issues>

=back

=head1 AUTHOR

Colin Kuskie <colink_at_plainblack_dot_com>

=head1 LEGAL

This module is Copyright 2019 Plain Black Corporation. It is distributed under the same terms as Perl itself. 

=cut

1;
