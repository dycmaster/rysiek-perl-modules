#!/usr/bin/perl
use 5.014;
use Dancer;
use Rysiek::Sensors;

Rysiek::Sensors::initSensors;
#$sensors->initSensors;


dance;
