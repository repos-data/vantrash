package App::VanTrash::Paypal;
use MooseX::Singleton;
use Business::PayPal::NVP;
use App::VanTrash::Config;
use namespace::clean -except => 'meta';

# Website Payments Pro and Express Checkout API Reference -
# https://www.x.com/docs/DOC-1372

has 'api' => (is => 'ro', isa => 'Business::PayPal::NVP', lazy_build => 1);
has 'model' => (is => 'ro', isa => 'Object', required => 1);

sub _build_api {
    my $self = shift;

    my $config = App::VanTrash::Config->new;
    my $branch = $config->Value('paypal_branch') or die "No paypal branch defined!";
    return Business::PayPal::NVP->new(
        branch => $branch,
        $branch => {
            user => $config->Value('paypal_user'),
            pwd => $config->Value('paypal_pwd'),
            sig => $config->Value('paypal_sig'),
        },
    );
}

sub set_up_subscription {
    my $self = shift;
    my %opts = @_;

    die "Invalid period - '$opts{period}'" unless $opts{period} =~ m/^(?:month|year)$/;
    die "Custom is required" unless $opts{custom};
    
    # SetExpressCheckout - https://www.x.com/docs/DOC-1208
    my $base_url = App::VanTrash::Config->base_url;
    my $p = $self->_subscription_opts($opts{period});
    my %resp = $self->api->SetExpressCheckout(
        AMT => $p->{amount},
        CURRENCYCODE => 'CAD',
        DESC => 'Vantrash Garbage Reminder Service',
        CUSTOM => $opts{custom},
        L_NAME0 => $p->{name},
        L_BILLINGTYPE0 => 'RecurringPayments',
        L_BILLINGAGREEMENTDESCRIPTION0 => $p->{desc},
        RETURNURL => "$base_url/billing/proceed",
        CANCELURL => "$base_url/billing/cancel",
        LANDINGPAGE => 'Billing',
    ) or do {
        warn "Error! " . join("\n", $self->api->errors);
        die "Could not create a VanTrash subscription payment. Try again later.\n";
    };

    my $paypal_base_url = 'https://www.paypal.com';
    if (App::VanTrash::Config->Value('paypal_branch') eq 'test') {
        $paypal_base_url = 'https://www.sandbox.paypal.com';
    }

    return "$paypal_base_url/cgi-bin/webscr?cmd=_express-checkout&token=$resp{TOKEN}";
}

sub _subscription_opts {
    my $self = shift;
    my $period = shift;

    my %period_opts = (
        month => {
            amount => '1.50',
            name => 'Monthly VanTrash Subscription',
            desc => '$1.50 per month for VanTrash notifications',
        },
        year => {
            amount => '15.00',
            name => 'Annual VanTrash Subscription',
            desc => '$15.00 per year for VanTrash notifications',
        },
    );
    return $period_opts{$period};
}

sub create_subscription {
    my $self = shift;
    my $token = shift;

    my %resp = $self->api->GetExpressCheckoutDetails(TOKEN => $token);
    die $resp{L_SHORTMESSAGE0} unless $resp{ACK} eq 'Success';
    die "Paypal billing agreement has not yet been accepted." 
        unless $resp{BILLINGAGREEMENTACCEPTEDSTATUS};
    my $rem = $self->model->reminders->by_id($resp{CUSTOM});
    die "Could not find reminder for '$resp{CUSTOM}'" unless $rem;
    
    my $p = $self->_subscription_opts($rem->payment_period);
    %resp = $self->api->CreateRecurringPaymentsProfile(
        TOKEN => $token,
        PROFILESTARTDATE => DateTime->now->iso8601,
        DESC => $p->{desc},
        MAXFAILEDPAYMENTS => 1,
        BILLINGPERIOD => ucfirst($rem->payment_period),
        BILLINGFREQUENCY => 1,
        AMT => $p->{amount},
        CURRENCYCODE => 'CAD',
    );
    die "Could not create recurring payment: $resp{L_SHORTMESSAGE0}"
        unless $resp{ACK} eq 'Success';

    my $profile_id = $resp{PROFILEID};
    $rem->subscription_profile_id($resp{PROFILEID});
    $rem->update;

    return $rem;
}

sub cancel_subscription {
    my $self = shift;
    my $profile_id = shift;

    my %resp = $self->api->ManageRecurringPaymentsProfileStatus(
        PROFILEID => $profile_id,
        ACTION => 'Cancel',
        NOTE => "Subscription cancelled at user's request.",
    );
    die "Could not cancel reminder using profile_id: $profile_id"
        unless $resp{ACK} eq 'Success';
}

__PACKAGE__->meta->make_immutable;
1;