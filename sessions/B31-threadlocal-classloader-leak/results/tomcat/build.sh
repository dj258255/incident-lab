set -e
mkdir -p /work/out/WEB-INF/classes
javac -cp /usr/local/tomcat/lib/servlet-api.jar \
      -d /work/out/WEB-INF/classes /work/src/leakapp/LeakServlet.java
cd /work/out && jar cf /work/leakapp.war .
