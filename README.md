Dune TV Prettifier
==================

Creates nice TV series listings for Dune HD media players, including various types of artwork, series and episode summaries, and stills.

For a more user-friendly solution, check out [Zappiti](http://zappiti.com/). This script is basically something I hacked together because Zappiti didn't suit me. I decided to release it, even though it's currently pretty rigid and somewhat error-prone. 

Full documentation will be available at some point.

Requirements
------------

* Perl 5 with some modules (see source)
* ImageMagick (specifically, `convert`)
* FFmpeg
* MediaInfo
* The awesome font [Cabin](http://www.impallari.com/cabin)
* An API key from [TheTVDB.com](http://thetvdb.com/)

Prerequisites
-------------

Currently, every series needs to be in a directory named after that series, containing a directory per season, containing all the media files for that season. An example would be `Fawlty Towers/S01/Fawlty Towers S01E03.avi`. The script will try its best to figure out the episode number from the file name. If that fails, it will just clean up the file name a bit; however, you will lose episode information.

Usage
-----

Grab the free font [Cabin](http://www.impallari.com/cabin) and place the files `Cabin-Regular.otf` and `Cabin-Bold.otf` in the same directory as the script. You can also use different fonts if you like; see below.

Then, get an API key at [TheTVDB.com](http://thetvdb.com/) and store it in a file called `.tvdb` in your home directory. 

Next, perform a syntax check to see which modules you're missing:

    perl -c dune-tv-prettifier.pl

You should be able to install each module using the CPAN shell, e.g.

    cpan File::Slurp

Once you have the required modules, you can run the script using

    perl dune-tv-prettifier.pl server share [mount]

where `server` is the host name or IP of the machine that hosts your TV collection (e.g., a NAS), `share` is the name of the NFS or Samba share on that machine, and `mount` is the local path where that share can be accessed. If `mount` is omitted, the script will default to the UNC path *//server/share* (which will probably only work on Windows).

If all goes well, the script will create a folder called `__Dune` inside that share, where it will store all its data. It will also create a `dune_folder.txt` file, which adds a root menu to your share. From there, you'll be able to access all your shows by browsing to the share on your Dune media player.

The script has many, many options, most of which allow you to tweak the visual style. Currently, their default values assume that your Dune player outputs full HD video; you'll need to tweak the options quite a bit if it doesn't. Other options you might need include:

* `--access-protocol`: By default, the script assumes that you're accessing your share using NFS. Set this to option `smb` if you use Samba. You can also specify login information using `--smb-username` and `--smb-password`.
* `--ffmpeg-path`, `--mediainfo-path`, and `--imagemagick-path`: If `ffmpeg`, `mediainfo`, and/or ImageMagick's `convert` aren't in your `PATH`, you'll need to specify their locations. In addition, because an entirely different `convert` is part of Windows itself, it is recommended that you always set `--imagemagick-path` on this platform.
* `--regular-font-file` and `--bold-font-file`: If you prefer not to use Cabin, you can specify the full paths to a different regular and/or bold TrueType or OpenType font file.

Author
------

[Tim De Pauw](http://pwnt.be/)

License
-------

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <http://www.gnu.org/licenses/>.
