package Rysiek::Actions::PlaySongOnRysiekMpd v0.0.1{
  use 5.014;
  use Moose;
  extends qw( Rysiek::Actions::AbstractAction );
  use Dancer;
  use Net::MPD;
  use Data::Dumper;
  use YAML::Tiny;

  
  sub doAction{
    my $self = shift;
    my $addParams = params->{addParams};    
    my $cfg  = $self->actionConfig();
    my($playlistName, $clear, $artistToSearch, $shuffle, $volume, $stop);
    debug"doing action: ".$self->name; 
    
    #check additional action info
    if (defined $addParams) {      
      my $yaml = YAML::Tiny->read_string( $addParams );
      debug Dumper($yaml);
      
      if (defined $yaml) {
        $playlistName = $yaml->[0]->{playlist};
        $clear = $yaml->[0]->{clear};
        $artistToSearch = $yaml->[0]->{artistToSearch};
        $shuffle = $yaml->[0]->{shuffle};
        $volume = $yaml->[0]->{volume};
        $stop = $yaml->[0]->{stop};
      }
    }
    
    
    my $mpd = Net::MPD->connect($cfg->[0]->{"mpdHostname"});    
    
    if (defined $stop) {
      $mpd->stop();
    }       
    
    if (defined $clear ) {
      debug("clearing old playlist..");
      $mpd->clear();
    }
    
    if (defined $volume ) {
      debug("new volume will be: $volume");
      $mpd->volume($volume);
    }
    
    if (defined $playlistName) {
      debug "playlist to play is: $playlistName";
      $mpd->clear;
      $mpd->load($playlistName);
    }
    
    if (defined $artistToSearch) {
      debug "artist to search is: $artistToSearch";
      $mpd->search_add(Artist => 'Trace Adkins');      
    }
    
    if (defined $shuffle ) {
      debug"shuffle!";
      $mpd->shuffle();
    }
    
    $mpd->play();
    debug"action done: ".$self->name; 
    return 1;
  }
  
  sub initPaths{
    my $self = shift;
    $self->SUPER::initPaths;
    
    #to do the action, user and token required
    get "/actions/play" => sub {
            return "yolo";
    };
    
    debug"Paths from PlaySongOnRysiekMpd";
    return 1;
  }

  1;
}
