#!/usr/bin/perl
use 5.020;
use Dancer;
use Rysiek::Actions;

my $actions = Rysiek::Actions->new;
$actions->initActions;


dance;
