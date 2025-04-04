MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
echo "root:password" | chpasswd

--//
Content-Type: application/node.eks.aws

apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${cluster_name}
    apiServerEndpoint: ${api_server_url}
    certificateAuthority: ${b64_cluster_ca}
    cidr: 172.20.0.0/16
  kubelet:
    flags:
    - "--node-labels=alpha.eksctl.io/cluster-name=${cluster_name},alpha.eksctl.io/nodegroup-name=${nodegroup_name},eks.amazonaws.com/nodegroup-image=al2023,eks.amazonaws.com/capacityType=ON_DEMAND"
    - "--cpu-manager-policy=static"
    - "--feature-gates=CPUManagerPolicyOptions=true,CPUManagerPolicyAlphaOptions=true"
    - "--cpu-manager-policy-options=strict-cpu-reservation=true"
    - "--reserved-cpus=0,1"
    - "--kube-reserved=cpu=1000m,memory=1Gi,ephemeral-storage=1Gi"
    - "--system-reserved=cpu=1000m,memory=1Gi,ephemeral-storage=1Gi"
    - "--kube-reserved-cgroup="
    - "--system-reserved-cgroup="

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
yum install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
cat > /usr/local/sbin/set_irq_affinity.sh << 'EOF'
#!/bin/bash
CPU_MASK=3
for IRQ_DIR in /proc/irq/[0-9]*; do
  IRQ=$(basename "$IRQ_DIR")
  if [ "$IRQ" -eq 0 ] || [ "$IRQ" -eq 2 ]; then
    continue
  fi
  echo "Setting IRQ $IRQ to CPU mask $CPU_MASK"
  echo "$CPU_MASK" > "$IRQ_DIR/smp_affinity"
done
for EFA_IRQ in $(grep -l efa /proc/irq/*/*/name | awk -F/ '{print $3}'); do
  echo "Setting EFA IRQ $EFA_IRQ to CPU mask $CPU_MASK"
  echo "$CPU_MASK" > "/proc/irq/$EFA_IRQ/smp_affinity"
done
EOF
chmod +x /usr/local/sbin/set_irq_affinity.sh
cat > /etc/systemd/system/irq-affinity.service << EOF
[Unit]
Description=Set IRQ Affinity for HPC Workloads
After=network.target efa.service
Wants=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/set_irq_affinity.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable irq-affinity.service
systemctl start irq-affinity.service

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/01-cpu-affinity.conf << EOF
[Manager]
CPUAffinity=0 1
EOF
systemctl daemon-reload

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
cat > /etc/sysctl.d/90-efa-hpc.conf << EOF
net.core.rmem_max = 25165824
net.core.wmem_max = 25165824
net.core.netdev_max_backlog = 8192
net.core.busy_poll = 1
net.core.busy_read = 50
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_sack = 0
kernel.numa_balancing = 0
kernel.randomize_va_space = 0
vm.nr_hugepages = 20000
EOF
sysctl -p /etc/sysctl.d/90-efa-hpc.conf

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
cat > /etc/systemd/system/disable-transparent-hugepage.service << EOF
[Unit]
Description=Disable transparent hugepage
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable disable-transparent-hugepage.service
systemctl start disable-transparent-hugepage.service

--//--
