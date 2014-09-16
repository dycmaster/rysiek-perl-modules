package Rysiek::Sensors 0.01{
  use 5.014;
  use Moose;
  use Socket;
  use Dancer ':syntax';


  sub getPort {
    my $proto = getprotobyname("tcp");
    my $iaddr   = inet_aton("localhost");
    my $paddr = sockaddr_in(0, $iaddr);
    socket(SOCK, PF_INET, SOCK_STREAM, $proto);
    connect(SOCK, $paddr);
    my $port = (sockaddr_in(getsockname(SOCK)))[0];
    close(SOCK);
    $port;
  }

  sub load_module {
    for (@_){
      (my $file = "$_.pm") =~ s{::}{/}g;
      require $file;
    }
  }

  sub initSensors{
    debug "Environment is: ". config->{environment};
    debug "Sensors to start:(" . @{config->{sensors}} .")";
    debug join ',', @{config->{sensors}};
    my $dancerPort = &getPort;
    set port => $dancerPort;
    debug "Dancer port will be $dancerPort";

    foreach my $sensor (@{config->{sensors}}){
      my $sensorModule="Rysiek::Sensors::$sensor";
      load_module $sensorModule;
      my $sensorInstance = $sensorModule->new( port => $dancerPort, name=>$sensor);
      $sensorInstance->init or die "Couldn't init $sensorModule";      
      debug "Loaded and initiated sensor: $sensorModule";
    }

  }

  1;
}
