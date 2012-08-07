#!/bin/sh
JQUERY_VERSION="1.7.1"
STROPHE_VERSION="1.0.2"
BOOTSTRAP_VERSION="1.4.0"
cd www_files/js
test -e jquery-$JQUERY_VERSION.min.js || wget http://code.jquery.com/jquery-$JQUERY_VERSION.min.js
test -e adhoc.js || wget -O adhoc.js "http://cgit.babelmonkeys.de/cgit.cgi/adhocweb/plain/js/adhoc.js?id=a4c0f5025877f4858576dba28bbb461f0581a5d1"
test -e strophe.min.js || (wget https://github.com/downloads/metajack/strophejs/strophejs-$STROPHE_VERSION.tar.gz && tar xzf strophejs-$STROPHE_VERSION.tar.gz strophejs-$STROPHE_VERSION/strophe.min.js --strip-components=1 && rm strophejs-$STROPHE_VERSION.tar.gz)
cd ../css
test -e bootstrap-$BOOTSTRAP_VERSION.min.css || wget http://twitter.github.com/bootstrap/$BOOTSTRAP_VERSION/bootstrap.min.css -O bootstrap-$BOOTSTRAP_VERSION.min.css
