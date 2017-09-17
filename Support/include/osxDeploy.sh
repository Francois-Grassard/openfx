#!/bin/bash

# Package all local libraries into an application or plugin bundle on OSX

# Author: Frederic Devernay <frederic.devernay@m4x.org>

# This script copies the .so, .la and .xml files needed to redistribute a mac application 
# This file is strongly inspired from the osx-app.sh script from the Inkscape source code

# In the XCode project, the "Runtime search paths" of your binaries should be set to
# "@loader_path/../Frameworks @loader_path/../Libraries" so that it finds libraries
# and frameworks at runtime.
# If using a Makefile, you should add the following flags at link time:
# -Wl,-rpath,@loader_path/../Frameworks -Wl,-rpath,@loader_path/../Libraries

# References:
# http://www.mikeash.com/pyblog/friday-qa-2009-11-06-linking-and-install-names.html
# http://www.dribin.org/dave/blog/archives/2009/11/15/rpath/

# env LANG=C is necessary so that sed doesn't try to interpret the binary file with a specific encoding
LANG=C
export LANG

if [ $# != 2 ]; then
    echo "Usage: $0 AppName.app|Bundle.bundle Executablename"
    echo "moves macports and local libraries into AppName.app"
    exit 1
fi

MACPORTS=/opt/local
HOMEBREW=/brew2/local
LOCAL=/usr/local

# add to PATH
PATH="$MACPORTS/bin:$HOMEBREW/bin:$LOCAL/bin:$PATH"

# sed adds a newline on OSX! http://stackoverflow.com/questions/13325138/why-does-sed-add-a-new-line-in-osx
# let's use gsed in binary mode.
# gsed is provided by the gsed package on MacPorts or the gnu-sed package on homebrew
# when using this variable, do not double-quote it ("$GSED"), because it contains options

# The default path obfuscations with the sed call would actually corrupt the binaries
# and make subsequent calls to install_name_tool fail with the following error:
# 'install_name_tool: the __LINKEDIT segment does not cover the end of the file (can't be processed)'

# use the gsed available in the PATH (works with homebrew and MacPorts)
if [[ ! $(type -P gsed) ]]; then
    echo "gsed (GNU sed) not available"
    echo "please install the gsed package on MacPorts, or the gnu-sed package on homebrew."
    exit 1
fi
GSED="gsed -b"

package="$1"
binary="$package/Contents/MacOS/$2"
libdir="Libraries"
pkglib="$package/Contents/$libdir"

if [ ! -x "$binary" ]; then
   echo "Error: $binary does not exist or is not an executable"
   exit 1
fi

rpath=`otool -l $binary | grep -A 3 LC_RPATH |grep path|awk '{ print $2 }'`
if [[ ! ("$rpath" == *"@loader_path/../$libdir"*) ]]; then
    echo "Error:: The runtime search path in $binary does not contain \"@loader_path/../$libdir\". Please set it in your Xcode project, or link the binary with the flags -Xlinker -rpath -Xlinker \"@loader_path/../$libdir\""
    exit 1
fi
# Test dirs
test -d "$pkglib" || mkdir "$pkglib"

LIBADD=

#############################
# test if ImageMagick is used
if otool -L "$binary"  | fgrep libMagick > /dev/null; then
    # Check that ImageMagick is properly installed
    if ! pkg-config --modversion ImageMagick >/dev/null 2>&1; then
        echo "Missing ImageMagick -- please install ImageMagick ('sudo port install ImageMagick +no_x11 +universal') and try again." >&2
        exit 1
    fi

    # Update the ImageMagick path in startup script.
    IMAGEMAGICKVER=`pkg-config --modversion ImageMagick`
    IMAGEMAGICKMAJ=${IMAGEMAGICKVER%.*.*}
    IMAGEMAGICKLIB=`pkg-config --variable=libdir ImageMagick`
    IMAGEMAGICKSHARE=`pkg-config --variable=prefix ImageMagick`/share
    # if I get this right, sed substitutes in the exe the occurences of IMAGEMAGICKVER
    # into the actual value retrieved from the package.
    # We don't need this because we use MAGICKCORE_PACKAGE_VERSION declared in the <magick/magick-config.h>
    # sed -e "s,IMAGEMAGICKVER,$IMAGEMAGICKVER,g" -i "" $pkgbin/DisparityKillerM

    # copy the ImageMagick libraries (.la and .so)
    cp -r "$IMAGEMAGICKLIB/ImageMagick-$IMAGEMAGICKVER" "$pkglib/"
    test -d "$pkglib/share" || mkdir "$pkglib/share"
    cp -r "$IMAGEMAGICKSHARE/ImageMagick-$IMAGEMAGICKMAJ" "$pkglib/share/"

    LIBADD="$LIBADD $pkglib/ImageMagick-$IMAGEMAGICKVER/modules-*/*/*.so"
    WITH_IMAGEMAGICK=yes
fi

# expand glob patterns in LIBADD
LIBADD=`echo $LIBADD`

# Find out the library dependencies
# (i.e. $LOCAL or $MACPORTS), then loop until no changes.
a=1
nfiles=0
alllibs=""
endl=true
while $endl; do
    #echo -e "\033[1mLooking for dependencies.\033[0m Round" $a
    pkglibs=
    if compgen -G "$pkglib/*" > /dev/null; then
        pkglibs=$pkglib/*
    fi
    libs="`otool -L $pkglibs $LIBADD $binary 2>/dev/null | fgrep compatibility | cut -d\( -f1 | grep -e $LOCAL'\\|'$HOMEBREW'\\|'$MACPORTS | sort | uniq`"
    if [ -n "$libs" ]; then
        cp -f $libs $pkglib
        alllibs="`ls $alllibs $libs | sort | uniq`"
    fi
    let "a+=1"      
    nnfiles=`ls $pkglib | wc -l`
    if [ $nnfiles = $nfiles ]; then
        endl=false
    else
        nfiles=$nnfiles
    fi
done

# all the libraries were copied, now change the names...
## We use @rpath instead of @executable_path/../$libdir because it's shorter
## than /opt/local, so it always works. The downside is that the XCode project
## has to link the binary with "Runtime search paths" set correctly
## (e.g. to "@loader_path/../Frameworks @loader_path/../Libraries" ),
## or the binary has to be linked with the following flags:
## -Wl,-rpath,@loader_path/../Frameworks -Wl,-rpath,@loader_path/../Libraries
if [ -n "$alllibs" ]; then
    changes=""
    for l in $alllibs; do
        changes="$changes -change $l @rpath/`basename $l`"
    done

    for f in  $pkglib/* $LIBADD "$binary"; do
        # avoid directories
        if [ -f "$f" ]; then
            chmod +w "$f"
            if ! install_name_tool $changes "$f"; then
                echo "Error: 'install_name_tool $changes $f' failed"
                exit 1
            fi
                `basename $f` "$f"
            if ! install_name_tool -id @rpath/`basename $f` "$f"; then
                echo "Error: 'install_name_tool -id @rpath/`basename $f` $f' failed"
                exit 1
            fi
        fi
    done
fi

#if [ "$WITH_IMAGEMAGICK" = "yes" ]; then
    # and now, obfuscate all the default paths in dynamic libraries
    # and ImageMagick modules and config files

    # generate a pseudo-random string which has the same length as $MACPORTS
    RANDSTR="R7bUU6jiFvqrPy6zLVPwIC3b93R2b1RG2qD3567t8hC3b93R2b1RG2qD3567t8h"
    MACRAND=${RANDSTR:0:${#MACPORTS}}
    HOMEBREWRAND=${RANDSTR:0:${#HOMEBREW}}
    LOCALRAND=${RANDSTR:0:${#LOCAL}}
    find $pkglib -type f -exec $GSED -e "s@$MACPORTS@$MACRAND@g" -e "s@$HOMEBREW@$HOMEBREWRAND@g" -e "s@$LOCAL@$LOCALRAND@g" -i "" {} \;
    $GSED -e "s@$MACPORTS@$MACRAND@g" -e "s@$HOMEBREW@$HOMEBREWRAND@g" -e "s@$LOCAL@$LOCALRAND@g" -i "$binary"
#fi
