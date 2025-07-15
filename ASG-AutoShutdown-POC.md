# AWS Auto Scaling Group 定时开关机 POC 配置指南

## 概述
本文档详细介绍如何在AWS宁夏区域配置Auto Scaling Group (ASG)实现定时开关机和CPU自动扩缩容功能：
- 晚上11点自动关机（设置Desired Capacity为0）
- 早上9点自动开机（设置Desired Capacity为2，最小2台）
- 开机时间段内基于CPU压力自动扩缩容（最小2台，最大6台）
- EC2实例类型：g4dn.xlarge

## 前置条件
- AWS CLI已配置china profile
- 具有相应的IAM权限
- 已有VPC和子网配置

## 步骤1：配置AWS CLI Profile

```bash
# 配置china profile
aws configure --profile china
# 输入Access Key ID
# 输入Secret Access Key
# 输入默认区域：cn-northwest-1 (宁夏区域)
# 输入默认输出格式：json

# 验证配置
aws sts get-caller-identity --profile china --region cn-northwest-1
```

## 步骤2：创建IAM角色和策略

### 2.1 创建EC2实例角色
```bash
# 创建信任策略文件
cat > ec2-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# 创建IAM角色
aws iam create-role \
  --role-name ASG-EC2-Role \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --profile china \
  --region cn-northwest-1

# 附加基本策略
aws iam attach-role-policy \
  --role-name ASG-EC2-Role \
  --policy-arn arn:aws-cn:iam::aws:policy/AmazonSSMManagedInstanceCore \
  --profile china \
  --region cn-northwest-1

# 创建实例配置文件
aws iam create-instance-profile \
  --instance-profile-name ASG-EC2-InstanceProfile \
  --profile china \
  --region cn-northwest-1

# 将角色添加到实例配置文件
aws iam add-role-to-instance-profile \
  --instance-profile-name ASG-EC2-InstanceProfile \
  --role-name ASG-EC2-Role \
  --profile china \
  --region cn-northwest-1
```

### 2.2 创建Auto Scaling服务角色
```bash
# 创建Auto Scaling信任策略
cat > autoscaling-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "application-autoscaling.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# 创建Auto Scaling角色
aws iam create-role \
  --role-name ASG-AutoScaling-Role \
  --assume-role-policy-document file://autoscaling-trust-policy.json \
  --profile china \
  --region cn-northwest-1

# 附加Auto Scaling策略
aws iam attach-role-policy \
  --role-name ASG-AutoScaling-Role \
  --policy-arn arn:aws-cn:iam::aws:policy/application-autoscaling/AWSApplicationAutoscalingEC2AutoScalingGroupPolicy \
  --profile china \
  --region cn-northwest-1
```

## 步骤3：获取必要的资源信息

```bash
# 获取VPC信息
aws ec2 describe-vpcs \
  --profile china \
  --region cn-northwest-1

# 获取子网信息
aws ec2 describe-subnets \
  --profile china \
  --region cn-northwest-1

# 获取最新的Amazon Linux 2 AMI ID
aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=amzn2-ami-hvm-*" "Name=architecture,Values=x86_64" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text \
  --profile china \
  --region cn-northwest-1
```

## 步骤4：创建安全组

```bash
# 创建安全组
aws ec2 create-security-group \
  --group-name ASG-POC-SG \
  --description "Security group for ASG POC" \
  --vpc-id vpc-xxxxxxxxx \
  --profile china \
  --region cn-northwest-1

# 添加SSH访问规则（根据需要调整源IP）
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxxx \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --profile china \
  --region cn-northwest-1
```

## 步骤5：创建启动模板

```bash
# 创建启动模板配置文件
cat > launch-template.json << EOF
{
  "LaunchTemplateName": "ASG-POC-LaunchTemplate",
  "LaunchTemplateData": {
    "ImageId": "ami-xxxxxxxxx",
    "InstanceType": "g4dn.xlarge",
    "SecurityGroupIds": ["sg-xxxxxxxxx"],
    "IamInstanceProfile": {
      "Name": "ASG-EC2-InstanceProfile"
    },
    "UserData": "$(echo '#!/bin/bash
yum update -y
yum install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
echo "Instance started at $(date)" > /var/log/startup.log' | base64 -w 0)",
    "TagSpecifications": [
      {
        "ResourceType": "instance",
        "Tags": [
          {
            "Key": "Name",
            "Value": "ASG-POC-Instance"
          },
          {
            "Key": "Environment",
            "Value": "POC"
          }
        ]
      }
    ]
  }
}
EOF

# 创建启动模板
aws ec2 create-launch-template \
  --cli-input-json file://launch-template.json \
  --profile china \
  --region cn-northwest-1
```

## 步骤6：创建Auto Scaling Group

```bash
# 创建Auto Scaling Group
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name ASG-POC-Group \
  --launch-template LaunchTemplateName=ASG-POC-LaunchTemplate,Version='$Latest' \
  --min-size 0 \
  --max-size 6 \
  --desired-capacity 2 \
  --vpc-zone-identifier "subnet-xxxxxxxxx,subnet-yyyyyyyyy" \
  --health-check-type EC2 \
  --health-check-grace-period 300 \
  --tags "Key=Name,Value=ASG-POC-Group,PropagateAtLaunch=true,ResourceId=ASG-POC-Group,ResourceType=auto-scaling-group" \
  --profile china \
  --region cn-northwest-1
```

## 步骤7：创建定时扩缩容策略

### 7.1 创建晚上11点关机的定时操作
```bash
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name ASG-POC-Group \
  --scheduled-action-name "Shutdown-11PM" \
  --recurrence "0 23 * * *" \
  --desired-capacity 0 \
  --min-size 0 \
  --max-size 6 \
  --profile china \
  --region cn-northwest-1
```

### 7.2 创建早上9点开机的定时操作
```bash
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name ASG-POC-Group \
  --scheduled-action-name "Startup-9AM" \
  --recurrence "0 9 * * *" \
  --desired-capacity 2 \
  --min-size 2 \
  --max-size 6 \
  --profile china \
  --region cn-northwest-1
```

## 步骤8：配置CPU自动扩缩容策略

### 8.1 创建扩容策略（CPU使用率高时）
```bash
# 创建扩容策略
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name ASG-POC-Group \
  --policy-name "CPU-ScaleOut-Policy" \
  --policy-type "TargetTrackingScaling" \
  --target-tracking-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ASGAverageCPUUtilization"
    },
    "ScaleOutCooldown": 300,
    "ScaleInCooldown": 300
  }' \
  --profile china \
  --region cn-northwest-1
```

### 8.2 创建简单扩容策略（备用方案）
```bash
# 创建简单扩容策略
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name ASG-POC-Group \
  --policy-name "CPU-ScaleOut-Simple" \
  --policy-type "SimpleScaling" \
  --adjustment-type "ChangeInCapacity" \
  --scaling-adjustment 1 \
  --cooldown 300 \
  --profile china \
  --region cn-northwest-1

# 获取扩容策略ARN
SCALE_OUT_POLICY_ARN=$(aws autoscaling describe-policies \
  --auto-scaling-group-name ASG-POC-Group \
  --policy-names "CPU-ScaleOut-Simple" \
  --profile china \
  --region cn-northwest-1 \
  --query 'ScalingPolicies[0].PolicyARN' --output text)

# 创建简单缩容策略
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name ASG-POC-Group \
  --policy-name "CPU-ScaleIn-Simple" \
  --policy-type "SimpleScaling" \
  --adjustment-type "ChangeInCapacity" \
  --scaling-adjustment -1 \
  --cooldown 300 \
  --profile china \
  --region cn-northwest-1

# 获取缩容策略ARN
SCALE_IN_POLICY_ARN=$(aws autoscaling describe-policies \
  --auto-scaling-group-name ASG-POC-Group \
  --policy-names "CPU-ScaleIn-Simple" \
  --profile china \
  --region cn-northwest-1 \
  --query 'ScalingPolicies[0].PolicyARN' --output text)
```

### 8.3 创建CloudWatch告警
```bash
# 创建CPU高使用率告警（触发扩容）
aws cloudwatch put-metric-alarm \
  --alarm-name "ASG-POC-CPU-High" \
  --alarm-description "Alarm when CPU exceeds 70%" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --threshold 70 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --alarm-actions $SCALE_OUT_POLICY_ARN \
  --dimensions Name=AutoScalingGroupName,Value=ASG-POC-Group \
  --profile china \
  --region cn-northwest-1

# 创建CPU低使用率告警（触发缩容）
aws cloudwatch put-metric-alarm \
  --alarm-name "ASG-POC-CPU-Low" \
  --alarm-description "Alarm when CPU below 30%" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --threshold 30 \
  --comparison-operator LessThanThreshold \
  --evaluation-periods 2 \
  --alarm-actions $SCALE_IN_POLICY_ARN \
  --dimensions Name=AutoScalingGroupName,Value=ASG-POC-Group \
  --profile china \
  --region cn-northwest-1
```

### 8.4 验证扩缩容策略
```bash
# 查看扩缩容策略
aws autoscaling describe-policies \
  --auto-scaling-group-name ASG-POC-Group \
  --profile china \
  --region cn-northwest-1

# 查看CloudWatch告警
aws cloudwatch describe-alarms \
  --alarm-names "ASG-POC-CPU-High" "ASG-POC-CPU-Low" \
  --profile china \
  --region cn-northwest-1
```

## 步骤10：测试CPU自动扩缩容功能

### 10.1 使用压力测试脚本
```bash
# 启动CPU压力测试
./cpu-stress-test.sh start

# 监控ASG状态
./cpu-stress-test.sh status

# 停止CPU压力测试
./cpu-stress-test.sh stop
```

### 10.2 手动测试CPU压力
```bash
# 连接到实例
aws ssm start-session --target i-xxxxxxxxx --profile china --region cn-northwest-1

# 在实例上安装stress工具
sudo yum install -y stress

# 启动CPU压力测试（使用所有CPU核心）
stress --cpu $(nproc) --timeout 600

# 在另一个终端监控CPU使用率
top
```

### 10.3 监控扩缩容过程
```bash
# 实时监控ASG活动
watch -n 30 'aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name ASG-POC-Group \
  --max-items 3 \
  --profile china --region cn-northwest-1 \
  --query "Activities[].{Time:StartTime,Description:Description,Status:StatusCode}"'

# 监控CloudWatch告警状态
aws cloudwatch describe-alarms \
  --alarm-names "ASG-POC-CPU-High" "ASG-POC-CPU-Low" \
  --profile china --region cn-northwest-1 \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason}'
```

### 10.4 验证扩缩容逻辑
1. **扩容测试**：
   - CPU使用率持续超过70%（2个评估周期，每个5分钟）
   - 触发扩容，增加1台实例
   - 冷却期300秒

2. **缩容测试**：
   - CPU使用率持续低于30%（2个评估周期，每个5分钟）
   - 触发缩容，减少1台实例
   - 但不会低于最小实例数（开机时间段为2台）

## 步骤11：验证配置

```bash
# 查看Auto Scaling Group状态
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names ASG-POC-Group \
  --profile china \
  --region cn-northwest-1

# 查看定时操作
aws autoscaling describe-scheduled-actions \
  --auto-scaling-group-name ASG-POC-Group \
  --profile china \
  --region cn-northwest-1

# 查看当前实例
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ASG-POC-Instance" \
  --profile china \
  --region cn-northwest-1
```

## AWS Console 配置步骤

### 1. 登录AWS Console
- 访问 https://console.amazonaws.cn/
- 选择宁夏区域 (cn-northwest-1)

### 2. 创建启动模板
1. 导航到 EC2 > 启动模板
2. 点击"创建启动模板"
3. 配置以下参数：
   - 启动模板名称：ASG-POC-LaunchTemplate
   - AMI：选择最新的Amazon Linux 2
   - 实例类型：g4dn.xlarge
   - 安全组：选择之前创建的安全组
   - IAM实例配置文件：ASG-EC2-InstanceProfile
   - 用户数据：添加启动脚本
4. 点击"创建启动模板"

### 3. 创建Auto Scaling组
1. 导航到 EC2 > Auto Scaling > Auto Scaling组
2. 点击"创建Auto Scaling组"
3. 步骤1：选择启动模板
   - 选择刚创建的启动模板
4. 步骤2：选择实例启动选项
   - 选择VPC和子网
5. 步骤3：配置高级选项
   - 运行状况检查：EC2
   - 运行状况检查宽限期：300秒
6. 步骤4：配置组大小和扩缩策略
   - 所需容量：1
   - 最小容量：0
   - 最大容量：2
7. 步骤5：添加通知（可选）
8. 步骤6：添加标签
9. 步骤7：审核并创建

### 4. 配置定时操作
1. 在Auto Scaling组详情页面
2. 点击"自动扩缩"选项卡
3. 在"计划的操作"部分点击"创建计划的操作"
4. 创建关机操作：
   - 名称：Shutdown-11PM
   - 所需容量：0
   - 最小容量：0
   - 最大容量：2
   - 重复周期：Cron表达式 `0 23 * * *`
5. 创建开机操作：
   - 名称：Startup-9AM
   - 所需容量：1
   - 最小容量：0
   - 最大容量：2
   - 重复周期：Cron表达式 `0 9 * * *`

## 监控和日志

### CloudWatch监控
```bash
# 查看Auto Scaling指标
aws cloudwatch get-metric-statistics \
  --namespace AWS/AutoScaling \
  --metric-name GroupDesiredCapacity \
  --dimensions Name=AutoScalingGroupName,Value=ASG-POC-Group \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-02T00:00:00Z \
  --period 3600 \
  --statistics Average \
  --profile china \
  --region cn-northwest-1
```

### 查看Auto Scaling活动
```bash
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name ASG-POC-Group \
  --profile china \
  --region cn-northwest-1
```

## 成本优化建议

1. **实例类型选择**：g4dn.xlarge适用于GPU工作负载，如果不需要GPU可考虑其他实例类型
2. **预留实例**：对于长期运行的工作负载，考虑购买预留实例
3. **Spot实例**：对于可中断的工作负载，考虑使用Spot实例
4. **监控成本**：设置成本预算和告警

## 故障排除

### 常见问题
1. **实例无法启动**
   - 检查AMI ID是否正确
   - 验证安全组配置
   - 确认子网有足够的IP地址

2. **定时操作不执行**
   - 检查Cron表达式格式
   - 验证时区设置（UTC时间）
   - 确认Auto Scaling组状态

3. **权限问题**
   - 验证IAM角色和策略
   - 检查服务关联角色

### 清理资源
```bash
# 删除Auto Scaling组
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name ASG-POC-Group \
  --force-delete \
  --profile china \
  --region cn-northwest-1

# 删除启动模板
aws ec2 delete-launch-template \
  --launch-template-name ASG-POC-LaunchTemplate \
  --profile china \
  --region cn-northwest-1

# 删除安全组
aws ec2 delete-security-group \
  --group-id sg-xxxxxxxxx \
  --profile china \
  --region cn-northwest-1
```

## 注意事项

1. **时区**：所有时间都是UTC时间，请根据本地时区调整
2. **成本**：g4dn.xlarge是GPU实例，成本较高，请注意监控
3. **数据持久化**：实例关闭时数据会丢失，重要数据请存储在EBS或S3
4. **网络**：确保子网配置正确，实例能够访问互联网进行软件更新

## 总结

本POC演示了如何使用AWS Auto Scaling Group实现EC2实例的定时开关机功能。通过合理配置，可以在非工作时间自动关闭实例以节省成本，在工作时间自动启动实例以确保服务可用性。
