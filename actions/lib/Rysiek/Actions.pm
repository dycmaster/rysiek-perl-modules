  package Rysiek::Actions 0.01{
    use 5.014;
    use Moose;
    use Socket;
    use Dancer ':syntax';
    use WebService::Belkin::WeMo::Discover;
    use WebService::Belkin::WeMo::Device;
    use Rysiek::Actions::AbstractAction;
    use strict;
    use warnings;


    sub getPort {
      my $proto = getprotobyname("tcp");
      my $iaddr   = inet_aton("localhost");
      my $paddr = sockaddr_in(0, $iaddr);
      socket(SOCK, PF_INET, SOCK_STREAM, $proto);
      connect(SOCK, $paddr);
      my $port = (sockaddr_in(getsockname(SOCK)))[0];
      close(SOCK);
      return $port;
    }

    sub load_module {
      for (@_){
        (my $file = "$_.pm") =~ s{::}{/}g;
        require $file;
      }
      return 1;
    }

    sub initWemo{
      my $wemoDiscover = WebService::Belkin::WeMo::Discover->new();

      unless( -e config->{wemoDb} ){
        my $discovered = $wemoDiscover->search();
        $wemoDiscover->save(config->{wemoDb});
      }
      return 1;
    }

    sub initActions{
      debug "Environment is: ". config->{environment};
      debug "Actions to start:(" . @{config->{actions}} .")";
      debug join ',', @{config->{actions}};
      my $dancerPort = &getPort;
      set port => $dancerPort;
      debug "Dancer port will be $dancerPort";

      &initWemo;
      
      #init tracking master only for AbstractAction
      Rysiek::Actions::AbstractAction->initStatic;
      

      foreach my $action (@{config->{actions}}){
        my $actionModule="Rysiek::Actions::$action";
        load_module $actionModule;
        my $actionInstance = $actionModule->new( port => $dancerPort, name=>$action);
        $actionInstance->init or die "Couldn't init $actionModule";
        debug "Loaded and initiated action: $actionModule";
      }
      return 1;
    }

    1;
  }
