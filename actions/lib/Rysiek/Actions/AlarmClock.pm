package Rysiek::Actions::AlarmClock v0.0.1{
  use 5.020;
  use Moose;
  use strict;
  use warnings;
  extends qw( Rysiek::Actions::AbstractAction );
  use Dancer ':syntax';
  use URI::Escape;

  sub doAction{
    my $self = shift;
    
    $self->SUPER::callActionViaMaster("SwitchAmpOn");
    
    my $addParams = uri_escape("playlist: alarmClock\nshuffle: yes\nvolume: 25\n");
    $self->SUPER::callActionViaMaster("PlaySongOnRysiekMpd", $addParams);
    
    return "AlarmClock done :) ring-ring!!";
  }  

  1;  
}

