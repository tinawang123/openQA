# Copyright (C) 2018 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Task::Asset::Limit;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Utils;
use Mojo::URL;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(limit_assets => sub { _limit($app, @_) });
}

sub _remove_if {
    my ($db, $asset) = @_;
    return if $asset->{fixed} || $asset->{pending};
    $db->resultset('Assets')->single({id => $asset->{id}})->delete;
}

sub _limit {
    my ($app, $j, $job, $url) = @_;

    # scan for untracked assets, refresh the size of all assets
    $app->db->resultset('Assets')->scan_for_untracked_assets();
    $app->db->resultset('Assets')->refresh_assets();

    my $asset_status = $app->db->resultset('Assets')->status(
        compute_pending_state_and_max_job => 1,
        compute_max_job_by_group          => 1,
    );
    my $assets = $asset_status->{assets};

    # first remove grouped assets
    for my $asset (@$assets) {
        if (keys %{$asset->{groups}} && !$asset->{picked_into}) {
            _remove_if($app->db, $asset);
        }
    }

    # use DBD::Pg as dbix doesn't seem to have a direct update call - find()->update are 2 queries
    my $dbh        = $app->schema->storage->dbh;
    my $update_sth = $dbh->prepare('UPDATE assets SET last_use_job_id = ? WHERE id = ?');

    # remove all assets older than a certain number of days which do not belong to a job group
    my $untracked_assets_storage_duration
      = $OpenQA::Utils::app->config->{misc_limits}->{untracked_assets_storage_duration};
    my $now = DateTime->now();
    for my $asset (@$assets) {
        $update_sth->execute($asset->{max_job} && $asset->{max_job} >= 0 ? $asset->{max_job} : undef, $asset->{id});
        next if $asset->{fixed} || scalar(keys %{$asset->{groups}}) > 0;

        my $age = int(DateTime::Format::Pg->parse_datetime($asset->{t_created})->delta_ms($now)->in_units('days'));
        if ($age >= $untracked_assets_storage_duration || !$asset->{size}) {
            _remove_if($app->db, $asset);
        }
        else {
            my $asset_name     = $asset->{name};
            my $remaining_days = $untracked_assets_storage_duration - $age;
            OpenQA::Utils::log_warning(
                "Asset $asset_name is not in any job group, will delete in $remaining_days days");
        }
    }

    # store the exclusively_kept_asset_size in the DB - for the job group edit field
    $update_sth = $dbh->prepare('UPDATE job_groups SET exclusively_kept_asset_size = ? WHERE id = ?');

    for my $group (values %{$asset_status->{groups}}) {
        $update_sth->execute($group->{picked}, $group->{id});
    }
}

1;
