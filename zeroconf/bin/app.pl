#!/usr/bin/perl
use 5.014;
use warnings;
use strict;
use Dancer;
use Rysiek::Zeroconf;

my $service = Rysiek::Zeroconf->new(name => config->{myName});
$service->init;
debug("let's dance!");

dance;