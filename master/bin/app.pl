#!/usr/bin/perl
use 5.014;
use Dancer;
use Rysiek::Master;

my $master = Rysiek::Master->new(name => config->{masterName});
$master->init;





dance;
