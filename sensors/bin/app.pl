#!/usr/bin/perl
use 5.014;
use Dancer;
use Rysiek::Sensors;

my $sensors = Rysiek::Sensors->new;
$sensors->initSensors;


dance;
