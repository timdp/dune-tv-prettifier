#!/usr/bin/perl

use strict;
use warnings;

use Carp qw(carp croak);
use Getopt::Long qw(GetOptions);
use WebService::TVDB qw();
use WebService::TVDB::Languages qw($languages);
use GD qw();
use File::Slurp qw(read_file write_file);
use File::Temp qw(:POSIX);
use File::Basename qw(dirname);
use Digest::MD5 qw(md5_hex);
use List::Util qw(max);
use Math::Round qw(round);
use Encode qw(encode_utf8);
use Text::Unidecode qw(unidecode);
use LWP::Simple qw(getstore is_success);
use JSON qw(encode_json decode_json);
use File::HomeDir qw(my_home);

$| = 1;

my ($renew_images, $renew_labels, $renew_stills);
my %opt = (
		'renew-images' => \$renew_images,
		'renew-labels' => \$renew_labels,
		'renew-stills' => \$renew_stills,
	);
my %config;
my $config_file = my_home() . '/.dune-tv-prettifier.json';
if (-f $config_file) {
	%config = %{read_json($config_file)};
} else {
	%config = (
			regular_font_file => dirname($0) . '/Cabin-Regular.otf',
			bold_font_file => dirname($0) . '/Cabin-Bold.otf',
			series_summary_font_size => 19,
			series_summary_leading => 1.5,
			series_summary_opacity => 1,
			episode_number_font_size => 19,
			episode_title_font_size => 21,
			episode_summary_font_size => 15,
			episode_summary_leading => 1.5,
			episode_summary_opacity => 0.5,
			season_list_font_size => 22,
			series_summary_max_height => 400,
			series_summary_padding => 40,
			episode_title_summary_margin => 11,
			episode_number_padding => 10,
			banner_font_size => 32,
			poster_font_size => 72,
			background_width => 1920,
			background_height => 1080,
			background_padding => 40,
			banner_width => 758,
			banner_height => 140,
			poster_width => 680,
			poster_height => 1000,
			episode_height => 120,
			episode_text_margin => 16,
			episode_summary_overflow => 15,
			episode_thumbnail_aspect_ratio => 16/9,
			episode_thumbnail_text_distance => 25,
			episode_padding_left => 40,
			episode_padding_right => 30,
			episodes_per_page => 6,
			scrollbar_width => 40,
			ribbon_offset => 200,
			ribbon_thickness => 80,
			ribbon_font_size => 32,
			ribbon_text_color => [ 255, 255, 255 ],
			ribbon_color => [ 191, 0, 0 ],
			ribbon_shadow_offset => 10,
			ribbon_shadow_opacity => 0.75,
			ribbon_text_shadow_offset => 3,
			placeholder_background_color => [ 15, 15, 15 ],
			placeholder_foreground_color => [ 191, 191, 191 ],
			backdrop_opacity => 0.1,
			dark_overlay_opacity => 0.2,
			light_overlay_opacity => 0.03,
			episode_number_background_opacity => 0.67,
			jpeg_quality => 90,
			cache_path => undef,
			mediainfo_path => undef,
			ffmpeg_path => undef,
			imagemagick_path => undef,
			data_dir_name => '__Dune',
			access_protocol => 'nfs',
			smb_username => undef,
			smb_password => undef
		);
	# TODO More robust option handling
	foreach my $key (keys %config) {
		(my $option_name = $key) =~ s/_/-/g;
		if ($key =~ /_color$/) {
			$opt{"$option_name=s"} = \&parse_color;
		} else {
			my $type = (defined $config{$key} && $config{$key} =~ /^[0-9.]+$/)
				? 'f' : 's';
			$opt{"$option_name=$type"} = \$config{$key};
		}
	}
	$opt{'language=s'} = $config{languages} = [];
	$opt{'extra-menu-item=s'} = $config{extra_menu_items} = [];
	$opt{'video-file-extension=s'} = $config{video_file_extensions} = [];
	$opt{'episode-filename-ignore=s'} = $config{episode_filename_ignore} = [];
}
GetOptions(%opt) or exit 1;
@{$config{languages}} = 'English'
	unless @{$config{languages}};
@{$config{video_file_extensions}} = qw(avi mkv mp4 m4v mpg wmv mov flv)
	unless @{$config{video_file_extensions}};

@ARGV < 2 and croak "Usage: $0 server share [mount]";
my ($server_name, $share_name, $base_path) = @ARGV;
$base_path = "//$server_name/$share_name" unless defined $base_path;

my $base_url;
if ($config{access_protocol} eq 'smb') {
	my $auth;
	if (defined $config{smb_username} && $config{smb_username} ne '') {
		require URI::Escape;
		$auth = URI::Escape::uri_escape($config{smb_username});
		$auth .= ':' . URI::Escape::uri_escape($config{smb_password})
			if defined $config{smb_password} && $config{smb_password} ne '';
		$auth .= '@';
	}
	$base_url = "$config{access_protocol}://$auth$server_name/$share_name";
} else {
	# NFS assumed
	$base_url = "$config{access_protocol}://$server_name:/$share_name";
}

$config{cache_path} = $base_path . '/' . $config{data_dir_name} . '/cache'
	unless defined $config{cache_path};

my %font_metrics = ();

my $dune_path = $base_path . '/' . $config{data_dir_name};
my $dune_url = $base_url . '/' . $config{data_dir_name};

mkdir "$dune_path";
mkdir "$dune_path/labels";
mkdir "$dune_path/content";
mkdir "$config{cache_path}";
mkdir "$config{cache_path}/banners";
mkdir "$config{cache_path}/stills";
mkdir "$config{cache_path}/info";

print 'Loading series list ...';
opendir(my $base_dh, $base_path)
	or croak qq{Cannot open directory "$base_path": $!};
my @subdirs = readdir($base_dh);
closedir($base_dh);
my @series = grep { /^[^._]/ && -d "$base_path/$_" } @subdirs;
print ' Found ', scalar(@series), $/;

print 'Checking modification times ...';
my %mtimes = ();
foreach my $series (@series) {
	my $series_path = "$base_path/$series";
	my $series_mtime = mtime($series_path);
	opendir(my $dh, $series_path)
		or croak qq{Cannot open directory "$series_path": $!};
	my @seasons = readdir($dh);
	closedir($dh);
	my $max_mtime = $series_mtime;
	foreach my $season (@seasons) {
		my $season_mtime = mtime("$series_path/$season");
		$mtimes{"$series/$season"} = $season_mtime;
		$max_mtime = max($max_mtime, $season_mtime);
	}
	$mtimes{$series} = $max_mtime;
}
print ' Stored ', scalar(keys %mtimes), $/;

@series = map { $_->[1] }
	sort { $b->[0] <=> $a->[0] }
	map { [ $mtimes{$_}, $_ ] }
	@series;

if (!$renew_labels && !$renew_stills && !$renew_images
		&& -e $base_path . '/dune_folder.txt'
		&& $mtimes{$series[0]} < mtime($base_path . '/dune_folder.txt')) {
	print "Everything up to date$/";
	exit;
}

my %tvdb_names = ();
my $name_file = "$dune_path/tvdb_names.txt";
if (-e $name_file) {
	open(my $fh, '<', $name_file)
		or croak qq{Cannot open "$name_file" for reading: $!};
	while (<$fh>) {
		/(.*?)=(.*)/ and $tvdb_names{$1} = $2;
	}
	close($fh);
}

my %tvdb_ids = ();
my $id_file = "$dune_path/tvdb_ids.txt";
if (-e $id_file) {
	open(my $fh, '<', $id_file)
		or croak qq{Cannot open "$id_file" for reading: $!};
	while (<$fh>) {
		/(.*)\s+(\d+)/ and $tvdb_ids{lc $1} = $2;
	}
	close($fh);
}

my @tvdbs = map {
		WebService::TVDB->new('language' => $_)
	} @{$config{languages}};

my $hd_gd = GD::Image->newFromPng(dirname($0) . '/hd.png', 1);

my $exts_re = join '|', map { quotemeta } @{$config{video_file_extensions}};

my $series_temp = tmpnam();
my $season_temp = tmpnam();

foreach my $series (@series) {
	print $series;

	my $series_info_file = "$config{cache_path}/info/$series.json";
	my $series_info = -e $series_info_file ? read_json($series_info_file) : {};

	opendir(my $dh, "$base_path/$series")
		or croak qq{Cannot open directory "$base_path/$series": $!};
	my @seasons = readdir($dh);
	closedir($dh);
	@seasons = sort_nicely(grep { $_ ne '.' && $_ ne '..' } @seasons);

	my $i = 0;
	while ($i < @seasons && $mtimes{"$series/$seasons[$i]"}) {
		$i++;
	}
	my $tree_ok = $mtimes{$series} && $i == @seasons;

	my $renew_series_images = $renew_images
		|| !exists $series_info->{content_box_y};
	my $renew_season_images = $renew_images || !$tree_ok;

	if (!$renew_images && !$renew_labels && !$renew_stills
			&& $series_info->{update_date}
			&& $mtimes{$series} < $series_info->{update_date}) {
		print " (up to date)$/";
		if ($renew_images) {
			next;
		} else {
			print "Skipping older content$/";
			last;
		}
	}
	print $/;

	mkdir "$dune_path/content/$series";

	my $tvdb_series = find_tvdb_series($series);
	my $series_name = defined $tvdb_series ? $tvdb_series->SeriesName : $series;

	my $cboxx = $config{background_padding} + $config{poster_width}
		+ $config{background_padding} + 1 + $config{background_padding};
	my $cboxw = $config{background_width} - $config{background_padding}
		- $config{poster_width} - $config{background_padding} - 1
		- $config{background_padding} - $config{background_padding};
	my ($cboxy, $poster_gd, $fanart_gd);

	if ($renew_series_images) {
		my $banner_gd;
		$banner_gd = find_banner($tvdb_series, 'series', 'graphical')
			if defined $tvdb_series;
		if (defined $banner_gd) {
			$banner_gd = scale_image($banner_gd,
				$config{banner_width}, $config{banner_height});
		} else {
			$banner_gd = create_placeholder($series,
				$config{banner_width}, $config{banner_height},
				$config{bold_font_file}, $config{banner_font_size});
		}
		write_image($banner_gd, "$dune_path/content/$series/banner.jpg", 1);
	}
	
	if ($renew_series_images || $renew_season_images) {
		$poster_gd = find_banner($tvdb_series, 'poster')
			if defined $tvdb_series;
		if (defined $poster_gd) {
			$poster_gd = scale_image($poster_gd,
				$config{poster_width}, $config{poster_height});
		} else {
			$poster_gd = create_placeholder($series,
				$config{poster_width}, $config{poster_height},
				$config{bold_font_file}, $config{poster_font_size});
		}
		
		if (defined $tvdb_series) {
			my @formats = ('1920x1080', '1280x720', undef);
			my $i = 0;
			while (!defined $fanart_gd && $i < @formats) {
				$fanart_gd = find_banner($tvdb_series, 'fanart', $formats[$i]);
				$i++;
			}
			if (defined $fanart_gd) {
				$fanart_gd = scale_image($fanart_gd,
					$config{background_width}, $config{background_height});
				my $tb = $fanart_gd->colorAllocateAlpha(0, 0, 0,
					round($config{backdrop_opacity} * 127));
				$fanart_gd->filledRectangle(0, 0,
					$fanart_gd->width - 1, $fanart_gd->height - 1,
					$tb);
			}
		}
		
		my $info = defined $tvdb_series ? $tvdb_series->Overview : undef;
		
		my $bg_gd = GD::Image->new(
			$config{background_width}, $config{background_height}, 1);
		if (defined $fanart_gd) {
			$bg_gd->copy($fanart_gd, 0, 0, 0, 0,
				$config{background_width}, $config{background_height});
		}
		my $black = $bg_gd->colorAllocate(0, 0, 0);
		my $white = $bg_gd->colorAllocate(255, 255, 255);
		$bg_gd->line($config{background_padding} + $config{poster_width}
				+ $config{background_padding},
			$config{background_padding},
			$config{background_padding} + $config{poster_width}
				+ $config{background_padding},
			$config{background_height} - $config{background_padding} - 1,
			$white);
		$bg_gd->copy($poster_gd,
			$config{background_padding}, $config{background_padding}, 0, 0,
			$config{poster_width}, $config{poster_height});

		if (defined $info) {
			my $x1 = $cboxx;
			my $y1 = $config{background_padding};
			my $bgcolor = overlay_color($bg_gd, 1);
			my $y = render_text($bg_gd, $info, $x1, $y1,
				$cboxw, $config{series_summary_max_height},
				$config{regular_font_file}, $config{series_summary_font_size},
				$config{series_summary_leading},
				$bg_gd->colorAllocateAlpha(255, 255, 255,
					round((1 - $config{series_summary_opacity}) * 127)),
				$bgcolor, $config{series_summary_padding});
			$cboxy = round($y + $config{background_padding} * 0.5);
		} else {
			$cboxy = $config{background_padding};
		}
		
		$bg_gd->filledRectangle(
			$cboxx, $cboxy,
			$config{background_width} - $config{background_padding} - 1,
			$config{background_height} - $config{background_padding} - 1,
			overlay_color($bg_gd, 0));

		write_image($bg_gd, "$dune_path/content/$series/background.jpg", 1);
		
		$series_info->{content_box_y} = $cboxy;
	} else {
		$cboxy = $series_info->{content_box_y};
	}
	
	my $cboxh = $config{background_height} - $config{background_padding} - $cboxy;
	my $cboxrows = round($cboxh / (pt2px($config{season_list_font_size}) * 3));
	
	open(my $series_fh, '>:utf8', $series_temp)
		or croak qq{Cannot open "$series_temp" for writing: $!};
	print $series_fh <<END;
system_files = *
sort_field = unsorted
animation_enabled = no
use_icon_view = yes
num_cols = 1
num_rows = $cboxrows
paint_captions = no
paint_path_box = no
paint_help_line = no
paint_icon_selection_box = yes
paint_content_box_background = no
direct_children.icon_valign = center
background_path = $dune_url/content/$series/background.jpg
background_x = 0
background_y = 0
content_box_x = $cboxx
content_box_y = $cboxy
content_box_height = $cboxh
END

	#
	# Seasons
	#

	$cboxy = $config{background_padding};
	$cboxh = $config{background_height} - $config{background_padding} - $cboxy;
	my $cboxrows2 = $config{episodes_per_page};
	
	my $scnt = 0;
	foreach my $season_id (@seasons) {
		print "  * $season_id$/";
		mkdir "$dune_path/content/$series/$season_id";
		my $path_season_num = ($season_id =~ /^S0*(\d+)$/) ? $1 : 0;
		my $caption = $path_season_num ? "Season $path_season_num" : $season_id;
		my $hash = create_label($caption,
			$config{regular_font_file}, $config{season_list_font_size});
		print $series_fh <<END;
item.$scnt.caption = -
item.$scnt.icon_path = $dune_url/labels/$hash.png
item.$scnt.media_url = $dune_url/content/$series/$season_id
item.$scnt.media_action = browse
END
		$scnt++;

		if ($renew_season_images) {
			my $season_poster_gd;
			if (defined $tvdb_series && $path_season_num) {
				$season_poster_gd = find_banner(
					$tvdb_series, 'season', undef, $path_season_num);
			}
			if (defined $season_poster_gd) {
				$season_poster_gd = scale_image(
					$season_poster_gd, $config{poster_width}, $config{poster_height});
			} else {
				$season_poster_gd = add_ribbon($poster_gd,
					$path_season_num ? "Season $path_season_num" : $season_id);
			}
			
			my $bg_gd = GD::Image->new(
				$config{background_width}, $config{background_height}, 1);
			if (defined $fanart_gd) {
				$bg_gd->copy($fanart_gd, 0, 0, 0, 0,
					$config{background_width}, $config{background_height});
			}
			my $black = $bg_gd->colorAllocate(0, 0, 0);
			my $white = $bg_gd->colorAllocate(255, 255, 255);
			$bg_gd->line($config{background_padding} + $config{poster_width}
					+ $config{background_padding},
				$config{background_padding},
				$config{background_padding} + $config{poster_width}
					+ $config{background_padding},
				$config{background_height} - $config{background_padding} - 1,
				$white);
			$bg_gd->copy($season_poster_gd,
				$config{background_padding}, $config{background_padding}, 0, 0,
				$config{poster_width}, $config{poster_height});

			$bg_gd->filledRectangle(
				$cboxx,
				$cboxy,
				$config{background_width} - $config{background_padding} - 1,
				$config{background_height} - $config{background_padding} - 1,
				overlay_color($bg_gd, 1));

			write_image($bg_gd,
				"$dune_path/content/$series/$season_id/background.jpg", 1);
		}
	
		opendir($dh, "$base_path/$series/$season_id")
			or croak qq{Cannot open directory "$base_path/$series/$season_id": $!};
		my @files = readdir($dh);
		closedir($dh);
		@files = sort_nicely(grep { /\.(?:$exts_re)$/i } @files);

		my $renew_season_labels = 0;
		if ($series_info->{files}{$season_id}) {
			my @known_files = keys %{$series_info->{files}{$season_id}};
			if (@known_files == @files) {
				@known_files = sort_nicely(@known_files);
				my $i = 0;
				while ($i < @files && $files[$i] eq $known_files[$i]) {
					$i++;
				}
				$renew_season_labels = ($i < @files);
			} else {
				$renew_season_labels = 1;
			}
		} else {
			$series_info->{files}{$season_id} = {};
			$renew_season_labels = 1;
		}

		open(my $season_fh, '>:utf8', $season_temp)
			or croak qq{Cannot open "$season_temp" for writing: $!};
		print $season_fh <<END;
system_files = *
sort_field = unsorted
animation_enabled = no
use_icon_view = yes
num_cols = 1
num_rows = $cboxrows2
paint_captions = no
paint_path_box = no
paint_help_line = no
paint_icon_selection_box = yes
paint_content_box_background = no
direct_children.icon_valign = center
background_path = $dune_url/content/$series/$season_id/background.jpg
background_x = 0
background_y = 0
content_box_x = $cboxx
content_box_y = $cboxy
content_box_height = $cboxh
END
		my @episode_records = ();
		foreach my $file (@files) {
			my (@ep_nums, $ep_title, $ep_summary, $order_num);
			my $tvdb_id = $tvdb_ids{lc "$series/$season_id/$file"};
			if (defined $tvdb_series && defined $tvdb_id) {
				my $episode = find_episode_by_id($tvdb_series, $tvdb_id);
				if (defined $episode) {
					$order_num = $episode->EpisodeNumber;
					@ep_nums = $episode->EpisodeNumber;
					$ep_title = $episode->EpisodeName;
					$ep_summary = $episode->Overview;
				} else {
					carp "$file: #$tvdb_id not found";
				}
			} else {
				my $season_num; # should be equal to $path_season_num
				($season_num, @ep_nums) = extract_episode_information($file);
				if ($season_num) {
					if (defined $tvdb_series) {
						my @titles = ();
						my $episode = find_episode_by_number($tvdb_series,
							$season_num, $ep_nums[0]);
						if (defined $episode) {
							$order_num = $ep_nums[0];
							$season_num = $episode->SeasonNumber;
							push @titles, $episode->EpisodeName;
							$ep_summary = $episode->Overview;
						}
						foreach my $ep_num (@ep_nums[1..$#ep_nums]) {
							$episode = find_episode_by_number($tvdb_series,
								$season_num, $ep_num);
							push @titles, $episode->EpisodeName
								if defined $episode;
						}
						if (@titles == 1) {
							$ep_title = $titles[0];
						} elsif (@titles) {
							if ($titles[0] =~ /^(.*) \((Part )?(\d+)\)$/) {
								my ($t, $p, $n) = ($1, $2, $3);
								$p = '' unless defined $p;
								my $i = 1;
								while ($i < @titles
										&& $titles[$i] eq "$t ($p" . ($n + $i) . ')') {
									$i++;
								}
								$ep_title = $t if $i == @titles;
							}
							$ep_title = join(' / ', @titles)
								unless defined $ep_title;
						}
					}
				} else {
					$ep_title = extract_episode_title($file, $series,
						$season_id eq 'Specials' ? 'Special' : $season_id);
					carp "Unknown: $file => $ep_title";
				}
			}
			if (!defined $ep_title || $ep_title eq '') {
				carp "No title: $file";
				$ep_title = '(Unknown)';
			}
			my ($vw, $vh);
			if (my $info = $series_info->{files}{$season_id}{$file}) {
				$vw = $info->{width};
				$vh = $info->{height};
			} else {
				($vw, $vh) = get_video_dimensions(
					"$base_path/$series/$season_id/$file");
				$series_info->{files}{$season_id}{$file}
					= { 'width' => $vw, 'height' => $vh };
			}
			my $record = [
					$order_num || ~0,
					$file,
					join('/', map { sprintf('%02d', $_) } @ep_nums),
					$ep_title,
					$ep_summary,
					is_hd_resolution($vw, $vh)
				];
			push @episode_records, $record;
		}
		@episode_records = sort { $a->[0] <=> $b->[0] } @episode_records;
		my $pager = @files > $cboxrows2;
		my $width = $cboxw - ($pager ? $config{scrollbar_width} : 0);
		my $cnt = 0;
		foreach my $r (@episode_records) {
			my ($sort_num, $file, $enum, $title, $summary, $is_hd) = @$r;
			my $hash = create_fancy_label(
				"$series/$season_id/$file", $enum, $title, $summary,
				$is_hd, $width, $renew_season_labels);
			my $caption = "$series_name - "
				. ($enum
					? ($path_season_num
							? $path_season_num . '.'
							: '')
						. $enum . ' - '
					: '')
				. $title;
			print $season_fh <<END;
item.$cnt.caption = $caption
item.$cnt.icon_path = $dune_url/labels/$hash.png
item.$cnt.media_url = $base_url/$series/$season_id/$file
END
			$cnt++;
		}
		print $season_fh 'content_box_width = ',
			$cboxw + ($pager ? 0 : $config{scrollbar_width}),
			$/;
		close($season_fh);
		try_rename($season_temp,
			"$dune_path/content/$series/$season_id/dune_folder.txt");
	}
	print $series_fh 'content_box_width = ',
		$cboxw + ($scnt <= $cboxrows ? $config{scrollbar_width} : 0), $/;
	close($series_fh);
	try_rename($series_temp,
		"$dune_path/content/$series/dune_folder.txt");

	$series_info->{update_date} = time;
	write_json($series_info, $series_info_file);
}

print 'Creating root menu ...';
@series = map { $_->[1] }
	sort { $a->[0] cmp $b->[0] }
	map { [ uc(strip_non_words(strip_article(unaccent($_)))), $_ ] }
	@series;
my $padding = $config{background_padding};
my $w = $config{background_width} - 2 * $config{background_padding};
my $h = $config{background_height} - 2 * $config{background_padding};
my $root_temp = tmpnam();
open(my $root_fh, '>:utf8', $root_temp)
	or croak qq{Cannot open "$root_temp" for writing: $!};
print $root_fh <<END;
system_files = *
sort_field = unsorted
animation_enabled = no
use_icon_view = yes
num_cols = 2
num_rows = 5
paint_captions = no
paint_path_box = no
paint_help_line = no
paint_icon_selection_box = yes
paint_content_box_background = no
direct_children.icon_valign = center
background_path = $dune_url/background_black.png
background_x = 0
background_y = 0
content_box_x = $padding
content_box_y = $padding
content_box_width = $w
content_box_height = $h
END
my $rcnt = 0;
foreach my $item (@{$config{extra_menu_items}}) {
	my ($path, $image) = split '=', $item;
	print $root_fh <<END;
item.$rcnt.caption = -
item.$rcnt.icon_path = $dune_url/$image
item.$rcnt.media_url = $base_url/$path
item.$rcnt.media_action = browse
END
	$rcnt++;
}
foreach my $series (@series) {
	print $root_fh <<END;
item.$rcnt.caption = -
item.$rcnt.icon_path = $dune_url/content/$series/banner.jpg
item.$rcnt.media_url = $dune_url/content/$series
item.$rcnt.media_action = browse
END
	$rcnt++;
}
close($root_fh);
try_rename($root_temp, $base_path . '/dune_folder.txt');
print " Done$/";

sub parse_color {
	my ($option, $str) = @_;
	(my $key = $option) =~ s/-/_/g;
	$str =~ /^(\d+),(\d+),(\d+)$/ or croak "Invalid color: $str";
	$config{$key} = [ $1, $2, $3 ];
}

sub extract_episode_title {
	my ($file, $series, $season_id) = @_;
	(my $ep_title = $file) =~ s/\.[^.]+$//;
	$ep_title =~ s/\./ /g;
	$ep_title =~ s/ {2,}/ /g;
	if (@{$config{episode_filename_ignore}}) {
		my $suffixes = join '|',
			map { quotemeta } @{$config{episode_filename_ignore}};
		$ep_title =~ s/ (?:$suffixes)[ \-].*//ig;
	}
	(my $s1 = $series) =~ s/[^A-Za-z0-9 \-]//g;
	$s1 = quotemeta $s1;
	my $s2 = quotemeta $series;
	my $s3 = quotemeta $season_id;
	1 while $ep_title =~ s/
			^
			(?:
				$s1
				|$s2
				|$s3
				|S\d\d?(?:E\d\d+)?
				|\d+x\d\d?
			)
			[\s\-]*
			(?:\s|$)
		//ix;
	return $ep_title;
}

sub extract_episode_information {
	my ($file) = @_;
	my ($season, @ep);
	if ($file =~ /
				(?:^|[.\ ])
				(?:S|jg)(\d\d?)
				(Ep?|afl)(\d\d?)
				(?:-?\2?(\d\d?))?
				(?:-?\2?(\d\d?))?
				[.\ ]
			/ix) {
		$season = $1;
		@ep = $3;
		push @ep, $4 if defined $4;
		push @ep, $5 if defined $5;
	} elsif ($file =~ /
				(?:^|[.\ ])
				Ep?(\d\d?)
				[.\ ]
			/ix) {
		$season = 1;
		@ep = $1;
	} elsif ($file =~ /
				(?:^|[.\ ])
				(\d\d?)
				x(\d\d?)
				[.\ ]
			/ix) {
		$season = $1;
		@ep = $2;
	} elsif ($file =~ /
				(?:^|[.\ ])
				(?:Part|Aflevering\ )(\d\d?)
				[.\ ]
			/ix) {
		$season = 1;
		@ep = $1;
	} elsif ($file =~ /
				(?:^|[.\ ])
				(\d\d?)of\d\d?
				[.\ ]
			/ix) {
		$season = 1;
		@ep = $1;
	} elsif ($file =~ /
				(?:^|[.\ ])
				([1-9])(\d\d)
				[.\ ]
			/ix) {
		$season = $1;
		@ep = $2;
	} elsif ($file =~ /
				(?:^|[.\ ])
				(\d\d)
				[.\ ]
			/ix) {
		$season = 1;
		@ep = $1;
	}
	unless (defined $season && $season > 0) {
		return 0;
	}
	$season = int $season;
	@ep = grep { $_ > 0 } map { int } @ep;
	unless (@ep) {
		return 0;
	}
	return ($season, @ep);
}

sub render_text {
	my ($img, $text, $x1, $y1, $width, $max_height,
		$font_file, $font_size, $leading,
		$font_color, $background_color, $padding) = @_;
	return unless defined $text && length $text;
	$padding = 0 unless defined $padding;
	my @words = split /\s/, $text;
	(my $line = shift @words) =~ s/&nbsp;/ /g;
	my @lines = ();
	my $text_width = $width - 2 * $padding;
	my $max_text_height = (defined $max_height ? $max_height : $img->height)
		- 2 * $padding;
	my $text_height = 0;
	my $metrics = get_font_metrics($font_file, $font_size);
	my $next_text_height = $metrics->{ascent};
	my $line_height = $metrics->{line_height};
	while (@words && $next_text_height <= $max_text_height) {
		(my $word = shift @words) =~ s/&nbsp;/ /g;
		my $new = "$line $word";
		my $w = get_text_width($new, $font_file, $font_size);
		if ($w > $text_width) {
			my $next_next = $next_text_height + $line_height * $leading;
			if ($next_next > $max_text_height) {
				$line = trim_line($line, $text_width,
					$font_file, $font_size, $font_color);
			}
			push @lines, $line;
			$line = $word;
			$text_height = $next_text_height;
			$next_text_height = $next_next;
		} else {
			$line = $new;
		}
	}
	if ($next_text_height <= $max_text_height) {
		push @lines, $line;
		$text_height = $next_text_height;
	}
	if (defined $background_color) {
		my $x2 = $x1 + $width - 1;
		my $y2 = $y1 + $padding + $text_height + $padding - 1;
		$img->filledRectangle($x1, $y1, $x2, $y2, $background_color);
	}
	my $y = $y1 + $padding;
	my @bounds;
	foreach my $line (@lines) {
		@bounds = $img->stringFT($font_color, $font_file, $font_size, 0,
			$x1 + $padding, $y + $metrics->{ascent}, $line);
		$y += $line_height * $leading;
	}
	$y += $padding;
	return wantarray
		? ($bounds[2], $y)
		: $y;
}

sub get_font_metrics {
	my ($font_file, $font_size) = @_;
	my $key = "${font_file}_$font_size";
	if (!exists $font_metrics{$key}) {
		my $c = 'X'; # Works best for ascent
		my @bounds = GD::Image->stringFT(
			0, $font_file, $font_size, 0, 0, 0, "$c\r\n$c");
		my $h = $bounds[1] - $bounds[7];
		@bounds = GD::Image->stringFT(
			0, $font_file, $font_size, 0, 0, 0, $c);
		my $ch = $bounds[1] - $bounds[7];
		$font_metrics{$key} = {
				'line_height' => $h - $ch,
				'ascent' => $ch
			};
	}
	return $font_metrics{$key};
}

sub get_text_width {
	my ($text, $font_file, $font_size) = @_;
	return (GD::Image->stringFT(0, $font_file, $font_size, 0, 0, 0, $text))[2];
}

sub trim_line {
	my ($line, $text_width, $font_file, $font_size, $font_color) = @_;
	$line =~ s/[.,;:?!\- ]*$//;
	my $width = get_text_width("$line &hellip;", $font_file, $font_size);
	while ($width > $text_width && $line =~ s/[.,;:?!\- ]* [^ ]+$//) {
		$width = get_text_width("$line &hellip;", $font_file, $font_size);
	}
	$line = "$line &hellip;";
	return $line;
}

sub create_fancy_label {
	my ($relpath, $number, $title, $info, $is_hd, $width, $force_renew) = @_;
	my $hash = md5_hex($relpath);
	my $file = "$dune_path/labels/$hash.png";
	if ($force_renew || $renew_labels || !-s $file) {
		my $overrun = 10;
		my $path = "$base_path/$relpath";
		my $thumbnail_height = $config{episode_height} - 2;
		my $thumbnail_width = round(
			$config{episode_thumbnail_aspect_ratio} * $thumbnail_height);
		my $x1 = $overrun + $config{episode_padding_left};
		my $y1 = $overrun;
		my $x2 = $x1 + 1 + $thumbnail_width + 1 - 1;
		my $y2 = $overrun + 1 + $thumbnail_height + 1 - 1;

		my $img = GD::Image->new(
			$width + 2 * $overrun,
			$config{episode_height} + 2 * $overrun,
			1);
		$img->saveAlpha(1);
		$img->alphaBlending(0);
		my $bg = $img->colorAllocateAlpha(0, 0, 0, 127);
		$img->fill(0, 0, $bg);
		$img->alphaBlending(1);
		my $white = $img->colorAllocate(255, 255, 255);
		my $still_img = get_video_still($path,
			$thumbnail_width, $thumbnail_height);
		if (defined $still_img) {
			my $still_ar = $still_img->width / $still_img->height;
			my ($x, $y, $w, $h);
			if ($config{episode_thumbnail_aspect_ratio} < $still_ar) {
				$h = $still_img->height;
				$w = round($h * $config{episode_thumbnail_aspect_ratio});
				$y = 0;
				$x = int(($still_img->width - $w) / 2);
			} else {
				$w = $still_img->width;
				$h = round($still_img->width / $config{episode_thumbnail_aspect_ratio});
				$x = 0;
				$y = int(($still_img->height - $h) / 2);
			}
			$img->copyResampled($still_img, 
				$overrun + $config{episode_padding_left} + 1, $overrun + 1, $x, $y,
				$thumbnail_width, $thumbnail_height, $w, $h);
		} else {
			my $black = $img->colorAllocate(0, 0, 0);
			$img->filledRectangle($x1 + 1, $y1 + 1, $x2 - 1, $y2 - 1, $black);
		}

		if (defined $number) {
			my $tw = get_text_width(
				$number, $config{bold_font_file}, $config{episode_number_font_size});
			my $m = get_font_metrics(
				$config{bold_font_file}, $config{episode_number_font_size});
			my $th = $m->{ascent};
			my $dark = $img->colorAllocateAlpha(0, 0, 0,
				round((1 - $config{episode_number_background_opacity}) * 127));
			$img->filledRectangle($x2 - 2 * $config{episode_number_padding} - $tw - 1,
				$y2 - 2 * $config{episode_number_padding} - $th - 1,
				$x2 - 1, $y2 - 1, $dark);
			$img->stringFT($white,
				$config{bold_font_file}, $config{episode_number_font_size},
				0, $x2 - $config{episode_number_padding} - $tw - 1,
				$y2 - $config{episode_number_padding} - 1,
				$number);
		}
		$img->rectangle($x1, $y1, $x2, $y2, $white);

		#my $hd_gap = $config{episode_thumbnail_text_distance};
		my $hd_gap = get_text_width('x',
			$config{bold_font_file}, $config{episode_title_font_size});

		my $x = $overrun + $config{episode_padding_left} + $thumbnail_width
			+ $config{episode_thumbnail_text_distance};
		my $y0 = $overrun + $config{episode_text_margin};
		my $w = $width - $x - $config{episode_padding_right};
		my $w2 = $w - ($is_hd ? $hd_gd->width + $hd_gap : 0);
		my ($xr, $y) = render_text($img, $title, $x, $y0,
			$w2, pt2px($config{episode_title_font_size}),
			$config{bold_font_file}, $config{episode_title_font_size},
			1, $white);
		if ($is_hd) {
			$img->copy($hd_gd, $xr + $hd_gap, $y0,
				0, 0, $hd_gd->width, $hd_gd->height);
		}
		$y += $config{episode_title_summary_margin};
		my $h = $config{episode_height} - $y - $config{episode_text_margin}
			+ $config{episode_summary_overflow};
		render_text($img, $info, $x, $y, $w, $h,
			$config{regular_font_file}, $config{episode_summary_font_size},
			$config{episode_summary_leading},
			$img->colorAllocateAlpha(255, 255, 255,
				round((1 - $config{episode_summary_opacity}) * 127)));

		write_image($img, $file);
	}
	return $hash;
}

sub get_video_still {
	my ($file, $width, $height) = @_;
	my $hash = md5_hex($file);
	my $still_path = "$config{cache_path}/stills/$hash.jpg";
	if ($renew_stills || !-s $still_path) {
		my $duration = get_media_duration($file);
		return undef unless defined $duration;
		my $time = $duration / 1000 / 2;
		my $ffmpeg = (defined $config{ffmpeg_path}
				? $config{ffmpeg_path} . '/' : '')
			. 'ffmpeg';
		my $cmd = qq{"$ffmpeg" -y -v 0 -ss $time -i "$file"}
			. qq { -vcodec mjpeg -vframes 1 -an -f rawvideo "$still_path"}
			. qq { >NUL 2>&1};
		my $status = system $cmd;
		if ($status) {
			carp qq{"$ffmpeg" terminated with status $status};
			return undef;
		}
	}
	return undef unless -s $still_path;
	return GD::Image->newFromJpeg($still_path, 1);
}

sub get_media_duration {
	my ($file) = @_;
	my $duration;
	my $mediainfo = (defined $config{mediainfo_path}
			? $config{mediainfo_path} . '/' : '')
		. 'mediainfo';
	open(my $ph, '-|', qq{"$mediainfo" -f "$file" 2>&1})
		or croak qq{Cannot invoke "$mediainfo": $!};
	while (!defined $duration && (my $line = <$ph>)) {
		if ($line =~ /^Duration\s+:\s+(\d+)\s*$/) {
			$duration = $1;
		}
	}
	close($ph);
	return $duration;
}

sub get_video_dimensions {
	my ($file) = @_;
	my ($width, $height);
	my $mediainfo = (defined $config{mediainfo_path}
			? $config{mediainfo_path} . '/' : '')
		. 'mediainfo';
	open(my $ph, '-|', qq{"$mediainfo" -f "$file" 2>&1})
		or croak qq{Cannot invoke "$mediainfo": $!};
	while ((!defined $width || !defined $height) && (my $line = <$ph>)) {
		if ($line =~ /^(Width|Height)\s+:\s+(\d+)\s*$/) {
			($1 eq 'Width' ? $width : $height) = $2;
		}
	}
	close($ph);
	return ($width, $height);
}

sub create_label {
	my ($str, $font_file, $font_size) = @_;
	my $hash = md5_hex(join("\0", @_));
	my $file = "$dune_path/labels/$hash.png";
	if ($renew_labels || !-s $file) {
		my $padding = 20;
		my $tw = get_text_width($str, $font_file, $font_size);
		my $m = get_font_metrics($font_file, $font_size);
		my $th = $m->{ascent};
		my $w = $tw + 2 * $padding;
		my $h = $th + 2 * $padding;
		my $img = GD::Image->new($w, $h, 1);
		$img->saveAlpha(1);
		$img->alphaBlending(0);
		my $black = $img->colorAllocateAlpha(0, 0, 0, 127);
		$img->fill(0, 0, $black);
		my $white = $img->colorAllocate(255, 255, 255);
		$img->stringFT($white,
			$font_file, $font_size, 0,
			($w - $tw) / 2, ($h + $th) / 2,
			$str);
		write_image($img, $file);
	}
	return $hash;
}

sub find_episode_by_id {
	my ($tvdb_series, $tvdb_id) = @_;
	foreach my $ep (@{$tvdb_series->episodes}) {
		if ($ep->id == $tvdb_id) {
			return $ep;
		}
	}
	return undef;
}

sub find_episode_by_number {
	my ($tvdb_series, $season_num, $ep_num) = @_;
	foreach my $ep (@{$tvdb_series->episodes}) {
		if ($ep->SeasonNumber == $season_num
				&& $ep->EpisodeNumber == $ep_num) {
			return $ep;
		}
	}
	return undef;
}

sub find_banner {
	my ($series, $type, $type2, $season_num) = @_;
	my @candidates = ();
	foreach my $banner (@{$series->banners}) {
		if (allowed_banner_language($banner->Language)
				&& $banner->BannerType eq $type
				&& (!defined $type2 || $banner->BannerType2 eq $type2)
				&& ($type ne 'season'
					|| ($banner->BannerType2 eq 'season'
						&& $banner->Season == $season_num))) {
			push @candidates, $banner;
		}
	}
	return undef unless @candidates;
	@candidates = sort { banner_rating($b) <=> banner_rating($a) } @candidates;
	if ($type ne 'season') {
		foreach my $banner (@candidates) {
			my $img = load_banner($banner);
			return $img if defined $img;
		}
		return undef;
	}
	# Assumes aspect ratios are correct
	my $largest;
	foreach my $banner (@candidates) {
		my $img = load_banner($banner);
		next unless defined $img;
		if ($img->width >= $config{poster_width}) {
			return $banner;
		}
		if (!defined $largest || $img->width > $largest->width) {
			$largest = $img;
		}
	}
	return $largest;
}

sub load_banner {
	my ($banner) = @_;
	my ($ext) = ($banner->BannerPath =~ /([^.]+)$/);
	my $cache_file = $config{cache_path} . '/banners/' . $banner->id . '.' . $ext;
	if (!-s $cache_file) {
		my $res = getstore($banner->url, $cache_file);
		return undef unless is_success($res);
	}
	return $ext eq 'png'
		? GD::Image->newFromPng($cache_file, 1)
		: GD::Image->newFromJpeg($cache_file, 1);
}

sub banner_rating {
	my ($banner) = @_;
	return defined $banner->Rating ? $banner->Rating : 0;
}

sub find_tvdb_series {
	my ($name) = @_;
	my $tvdb_name = encode_utf8(
		exists $tvdb_names{$name} ? $tvdb_names{$name} : $name);
	my $tvdb_series;
	my $i = 0;
	while ($i < @tvdbs && !defined $tvdb_series) {
		my $results = $tvdbs[$i]->search($tvdb_name);
		if (@$results) {
			$tvdb_series = $results->[0];
			$tvdb_series->fetch();
		}
		$i++;
	}
	return $tvdb_series;
}

sub is_hd_resolution {
	my ($width, $height) = @_;
	return ($width / $height < 16 / 9) ? ($height >= 720) : ($width >= 1280);
}

sub allowed_banner_language {
	my ($abbr) = @_;
	return 0 unless defined $abbr;
	foreach my $lang (@{$config{languages}}) {
		return 1 if ($abbr eq $languages->{$lang}->{abbreviation});
	}
	return 0;
}

sub scale_image {
	my ($img, $width, $height) = @_;
	if ($img->width == $width && $img->height == $height) {
		return $img;
	}
	my $in_file = tmpnam();
	my $out_file = tmpnam();
	write_image($img, $in_file);
	my $convert = (defined $config{imagemagick_path}
			? $config{imagemagick_path} . '/' : '')
		. 'convert';
	my $status = system $convert,
		$in_file,
		#'-filter', 'Lanczos',
		'-resize', "${width}x${height}!",
		'-unsharp', '0x0.5',
		$out_file;
	unlink $in_file;
	if ($status) {
		carp qq{"$convert" terminated with status $status};
		return undef;
	}
	$img = GD::Image->newFromPng($out_file, 1);
	unlink $out_file;
	return $img;
}

sub create_placeholder {
	my ($title, $width, $height, $font_file, $font_size) = @_;
	my $img = GD::Image->new($width, $height);
	my $bg = $img->colorAllocate(@{$config{placeholder_background_color}});
	my $fg = $img->colorAllocate(@{$config{placeholder_foreground_color}});
	my $w = get_text_width($title, $font_file, $font_size);
	my $m = get_font_metrics($font_file, $font_size);
	my $h = $m->{ascent};
	$img->stringFT($fg,
		$font_file, $font_size, 0,
		($width - $w) / 2, ($height + $h) / 2,
		$title);
	return $img;
}

sub add_ribbon {
	my ($img, $text) = @_;
	$text = uc $text;
	my $img2 = GD::Image->new($img->width, $img->height, 1);
	$img2->copy($img, 0, 0, 0, 0, $img->width, $img->height);
	my $poly = GD::Polygon->new;
	$poly->addPt(
			$img2->width - 1,
			$img2->height - 1 - $config{ribbon_offset} - $config{ribbon_thickness} / 2
		);
	$poly->addPt(
			$img2->width - 1,
			$img2->height - 1 - $config{ribbon_offset} + $config{ribbon_thickness} / 2
		);
	$poly->addPt(
			$img2->width - 1 - $config{ribbon_offset} + $config{ribbon_thickness} / 2,
			$img2->height - 1
		);
	$poly->addPt(
			$img2->width - 1 - $config{ribbon_offset} - $config{ribbon_thickness} / 2,
			$img2->height - 1
		);
	$poly->offset(0, $config{ribbon_shadow_offset});
	$img2->filledPolygon($poly, $img2->colorAllocateAlpha(
		0, 0, 0, round((1 - $config{ribbon_shadow_opacity}) * 127)));
	$poly->offset(0, - $config{ribbon_shadow_offset});
	$img2->filledPolygon($poly, $img2->colorAllocate(@{$config{ribbon_color}}));
	my $center_x = $img2->width - $config{ribbon_offset} / 2;
	my $center_y = $img2->height - $config{ribbon_offset} / 2;
	my $w = get_text_width($text, $config{bold_font_file}, $config{ribbon_font_size});
	my $m = get_font_metrics($config{bold_font_file}, $config{ribbon_font_size});
	my $h = $m->{ascent};
	my $dw = $w / 2 / sqrt(2);
	my $dh = $h / 2 / sqrt(2);
	my $x = $center_x - $dw + $dh;
	my $y = $center_y + $dh + $dw;
	my $angle = atan2(1, 1);
	$img2->stringFT($img->colorAllocate(0, 0, 0),
		$config{bold_font_file}, $config{ribbon_font_size}, $angle,
		$x + $config{ribbon_text_shadow_offset},
		$y + $config{ribbon_text_shadow_offset},
		$text);
	$img2->stringFT($img->colorAllocate(@{$config{ribbon_text_color}}),
		$config{bold_font_file}, $config{ribbon_font_size}, $angle, $x, $y, $text);
	return $img2;
}

sub overlay_color {
	my ($img, $light) = @_;
	my ($comp, $alpha) = $light
		? (255, 1 - $config{light_overlay_opacity})
		: (0, 1 - $config{dark_overlay_opacity});
	return $img->colorAllocateAlpha($comp, $comp, $comp, round($alpha * 127));
}

sub write_image {
	my ($img, $file, $jpeg) = @_;
	open(my $fh, '>', $file)
		or croak qq{Cannot open file "$file" for writing: $!};
	binmode($fh);
	print $fh $jpeg ? $img->jpeg($config{jpeg_quality}) : $img->png();
	close($fh);
}

sub read_json {
	my ($path) = @_;
	my $contents = read_file($path, 'binmode' => ':utf8');
	return decode_json($contents);
}

sub write_json {
	my ($data, $path) = @_;
	my $contents = encode_json($data);
	write_file($path, { 'binmode' => ':utf8' }, $contents);
}

sub try_rename {
	my ($src, $dest) = @_;
	rename $src, $dest or croak qq{Cannot rename "$src" to "$dest": $!};
}

sub sort_nicely {
	return map { $_->[1] }
		sort { $a->[0] cmp $b->[0] }
		map { [ uc(strip_non_words(unaccent($_))), $_ ] } @_;
}

sub strip_non_words {
	my ($str) = @_;
	$str =~ s/[^A-Za-z0-9]//g;
	return $str;
}

sub strip_article {
	my ($str) = @_;
	$str =~ s/^(?:(?:the|a|an|das|der|het|de|een|le|la|les|un|une|des)\s+|l')//i;
	return $str;
}

sub unaccent {
	my ($in) = @_;
	utf8::encode($in) unless utf8::is_utf8($in);
	return unidecode($in);
}

sub mtime {
	my ($path) = @_;
	return (stat($path))[9];
}

sub pt2px {
	my ($pt) = @_;
	return $pt * 96 / 72;
}
