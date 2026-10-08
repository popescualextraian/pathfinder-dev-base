FROM agentic-dev-base:local
USER root
COPY defaults/agentic.yaml /opt/agentic/defaults/agentic.yaml
COPY tools/ /opt/agentic/tools/
COPY skills/ /opt/agentic/skills/
COPY start.d/ /opt/agentic/start.d/
COPY worker.d/ /opt/agentic/worker.d/
RUN chmod 755 /opt/agentic/start.d/45-overlay.sh /opt/agentic/worker.d/fake.sh \
 && chmod 644 /opt/agentic/tools/hello.sh
USER dev
