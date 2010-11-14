package App::VanTrash::Reminders;
use Moose;
use namespace::clean -except => 'meta';

extends 'App::VanTrash::Collection';

has 'schema' => (is => 'rw', required => 1);

sub by_id   { shift->search_by(id           => @_)->first }
sub by_hash { shift->search_by(confirm_hash => @_)->first }
sub by_email { shift->search_by(email => @_)->all }

sub add {
    my $self = shift;
    my $rem = shift;

    $rem->{id} = _build_uuid('vantrash', $rem);
    $rem->{offset}        = -6 unless defined $rem->{offset};
    $rem->{confirmed}     = 0;
    $rem->{created_at}    = time;
    $rem->{last_notified} = time;
    $rem->{confirm_hash}  = _build_uuid('vantrash-confirm', $rem);

    my $robj = $self->_rs->create($rem);
    return $robj;
}

sub Is_valid_target {
    my $class = shift;
    my $target = shift;
    return $target =~ m/^(?:email|twitter|webhook|sms|voice):/;
}

sub _build_uuid { 
    my $namespace = shift;
    my $hash = shift;
    my $name = join '-', grep { defined } values %$hash;
    return Data::UUID->new->create_from_name_str($namespace, $name);
}

__PACKAGE__->meta->make_immutable;
1;
