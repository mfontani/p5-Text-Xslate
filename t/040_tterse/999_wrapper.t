#!perl -w
use strict;
use Test::More;

use Text::Xslate;
use t::lib::Util;
use t::lib::TTSimple;

my ($in, $vars, $out, $msg);
my $tx = Text::Xslate->new(path => [path], cache => 0);

($in, $vars, $out, $msg) = (
    <<'T', { lang => 'Xslate' }, <<'X', 'cascade-with as a macro library');
: cascade with common
: em('foo')
T
<em>foo</em>
X
is $tx->render_string($in, $vars), $out, $msg or diag $in;

($in, $vars, $out, $msg) = (
    <<'T', <<'X', 'CASCADE WITH as a macro library');
[% CASCADE WITH "config.tt" %]
[% em('foo') %]
T
<em>foo</em>
X
my %vars = (lang => 'Xslate', foo => "<bar>", '$lang' => 'XXX');
is render_str($in, \%vars), $out, $msg
    or diag $in;

done_testing;
