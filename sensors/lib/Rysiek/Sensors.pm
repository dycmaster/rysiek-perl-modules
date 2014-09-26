package Rysiek::Sensors 0.01{
  use 5.014;
  use Socket;
  use Dancer ':syntax';
  use threads;
  use threads::shared;
  use Thread::Queue;
  use LWP::UserAgent;
  use LWP::Simple qw(get);
  use HTTP::Request::Common qw(POST);
  use Time::HiRes qw/time sleep/;
  use Data::Dumper;


  our $zeroconfServiceLink = "";
  my %mastersToTrack : shared = ();
  our $postQ = Thread::Queue->new();


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

    &initWorkerThread;

    foreach my $sensor (@{config->{sensors}}){
      my $sensorModule="Rysiek::Sensors::$sensor";
      load_module $sensorModule;
      my $sensorInstance = $sensorModule->new( port => $dancerPort, name=>$sensor);
      $sensorInstance->init or die "Couldn't init $sensorModule";      
      debug "Loaded and initiated sensor: $sensorModule";
    }

  }
  
  sub initWorkerThread{
    say "creating and starting worker thread";
    my $worker = threads->create(
      sub{
        $|=1;
        sleep 5;
        my ($lastWorkerStart, $lastMasterTrackTime) = (time, time);
        my $masterUpdateF = config->{masterCheckerFrequency};

        while(1){
          $lastWorkerStart=time;
          &handleRequestsFromQueue;

          if(time - $lastMasterTrackTime >= $masterUpdateF){
            &checkMasters;
            $lastMasterTrackTime = time;
          }

          my $elasped = (time - $lastWorkerStart) * 1000;
          my $workerPeriod = config->{workerPeriod};
          if ( $elasped < $workerPeriod ) {                                                         
            my $timeToSleep = ( $workerPeriod - $elasped ) / 1000;
            sleep($timeToSleep);
          }
        }
      }
    );
    say "detaching worker";
    $worker->detach();
    return 1;
  }
  
  sub handleRequestsFromQueue{
    $|=1;
    while($postQ->pending() > 0 ){
      my $item = $postQ->dequeue();
      my $url = $item->{url};
      my $content = $item->{content};
      my $sender = $item->{sender};
      say("Processing request from $sender: $url");

      {
        lock(%mastersToTrack);
        if(defined $mastersToTrack{$item->{master}} 
          && $mastersToTrack{$item->{master}}{available} == 1 ){
          my $ua = LWP::UserAgent->new;
          my $res = $ua->request(POST  "$url", $content  );

          # Check the outcome of the response
          if (!$res->is_success) {
            say("unable to send $url");
          }else{
            say("request: $url from $sender done OK" );
          }
        }else{
          say"request from $sender to a master $item->{master} which is not currently available!" 
          ."Skipping....";
        }
      }

    }
    return 1;
  }

  #new mastersToTrack are added from sensors, when masters register to some sensor
  sub checkMasters{
    $|=1;
    {
      lock(%mastersToTrack);
      my $mSize = keys %mastersToTrack;
      foreach my $master (keys %mastersToTrack){
        my $masterIp = $mastersToTrack{$master}{ip};
        my $masterPort = $mastersToTrack{$master}{port};
        my $url = "http://". $masterIp .":". $masterPort ."/masters/". $master ."/ping";

        my $res = LWP::Simple::get($url);

        if(!defined $res){
          if($mastersToTrack{$master}{available} == 1){
            say("Master ". $master ." is not available and will be marked so..");
          }
          $mastersToTrack{$master}{available}=0;
        }else{
          if($mastersToTrack{$master}{available}== 0){
            say "master $master is here :)) ";
          }
          $mastersToTrack{$master}{available}=1;
          $mastersToTrack{$master}{lastSeen}= time;
        }
      }
    }
  }

  #this is called from a sensor, as a class method, (not object method!), when some master 
  #subscribes to a given sensor
  sub addMasterToTrack{
    $|=1;
    my $newMaster=shift;
    {
      lock(%mastersToTrack);
      my %masterData : shared = ();
      $masterData{ip}=$newMaster->{ip};
      $masterData{port}=$newMaster->{port};
      $masterData{available}=1;

      $mastersToTrack{$newMaster->{name}}=\%masterData;
    }
    1;
  }

  1;
}
