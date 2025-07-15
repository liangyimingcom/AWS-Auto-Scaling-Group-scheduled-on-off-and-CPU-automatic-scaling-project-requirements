#!/bin/bash

# ASG定时开关机POC部署脚本
# 使用方法: ./deploy-asg.sh

set -e

# 配置变量
PROFILE="china"
REGION="cn-northwest-1"
ASG_NAME="ASG-POC-Group"
LAUNCH_TEMPLATE_NAME="ASG-POC-LaunchTemplate"
SECURITY_GROUP_NAME="ASG-POC-SG"

echo "开始部署ASG定时开关机POC..."

# 检查AWS CLI配置
echo "检查AWS CLI配置..."
aws sts get-caller-identity --profile $PROFILE --region $REGION

# 获取账户ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile $PROFILE --region $REGION --query Account --output text)
echo "账户ID: $ACCOUNT_ID"

# 获取默认VPC
echo "获取VPC信息..."
VPC_ID=$(aws ec2 describe-vpcs --profile $PROFILE --region $REGION --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
    echo "未找到默认VPC，请手动指定VPC ID"
    exit 1
fi
echo "使用VPC: $VPC_ID"

# 获取子网
echo "获取子网信息..."
SUBNET_IDS=$(aws ec2 describe-subnets --profile $PROFILE --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text)
SUBNET_LIST=$(echo $SUBNET_IDS | tr ' ' ',')
echo "使用子网: $SUBNET_LIST"

# 获取最新的Amazon Linux 2 AMI
echo "获取最新AMI..."
AMI_ID=$(aws ec2 describe-images --profile $PROFILE --region $REGION \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*" "Name=architecture,Values=x86_64" "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)
echo "使用AMI: $AMI_ID"

# 创建IAM角色
echo "创建IAM角色..."
aws iam create-role \
    --role-name ASG-EC2-Role \
    --assume-role-policy-document file://ec2-trust-policy.json \
    --profile $PROFILE \
    --region $REGION || echo "角色可能已存在"

aws iam attach-role-policy \
    --role-name ASG-EC2-Role \
    --policy-arn arn:aws-cn:iam::aws:policy/AmazonSSMManagedInstanceCore \
    --profile $PROFILE \
    --region $REGION || echo "策略可能已附加"

aws iam create-instance-profile \
    --instance-profile-name ASG-EC2-InstanceProfile \
    --profile $PROFILE \
    --region $REGION || echo "实例配置文件可能已存在"

aws iam add-role-to-instance-profile \
    --instance-profile-name ASG-EC2-InstanceProfile \
    --role-name ASG-EC2-Role \
    --profile $PROFILE \
    --region $REGION || echo "角色可能已添加"

# 等待IAM角色生效
echo "等待IAM角色生效..."
sleep 10

# 创建安全组
echo "创建安全组..."
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name $SECURITY_GROUP_NAME \
    --description "Security group for ASG POC" \
    --vpc-id $VPC_ID \
    --profile $PROFILE \
    --region $REGION \
    --query 'GroupId' --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
    --group-names $SECURITY_GROUP_NAME \
    --profile $PROFILE \
    --region $REGION \
    --query 'SecurityGroups[0].GroupId' --output text)

echo "安全组ID: $SECURITY_GROUP_ID"

# 添加SSH访问规则
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --profile $PROFILE \
    --region $REGION || echo "SSH规则可能已存在"

# 创建启动模板
echo "创建启动模板..."
USER_DATA=$(echo '#!/bin/bash
yum update -y
yum install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
echo "Instance started at $(date)" > /var/log/startup.log' | base64)

cat > launch-template-config.json << EOF
{
  "LaunchTemplateName": "$LAUNCH_TEMPLATE_NAME",
  "LaunchTemplateData": {
    "ImageId": "$AMI_ID",
    "InstanceType": "g4dn.xlarge",
    "SecurityGroupIds": ["$SECURITY_GROUP_ID"],
    "IamInstanceProfile": {
      "Name": "ASG-EC2-InstanceProfile"
    },
    "UserData": "$USER_DATA",
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

aws ec2 create-launch-template \
    --cli-input-json file://launch-template-config.json \
    --profile $PROFILE \
    --region $REGION || echo "启动模板可能已存在"

# 创建Auto Scaling Group
echo "创建Auto Scaling Group..."
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name $ASG_NAME \
    --launch-template LaunchTemplateName=$LAUNCH_TEMPLATE_NAME,Version='$Latest' \
    --min-size 0 \
    --max-size 6 \
    --desired-capacity 2 \
    --vpc-zone-identifier "$SUBNET_LIST" \
    --health-check-type EC2 \
    --health-check-grace-period 300 \
    --tags "Key=Name,Value=$ASG_NAME,PropagateAtLaunch=true,ResourceId=$ASG_NAME,ResourceType=auto-scaling-group" \
    --profile $PROFILE \
    --region $REGION || echo "ASG可能已存在"

# 创建定时操作
echo "创建定时关机操作（晚上11点）..."
aws autoscaling put-scheduled-update-group-action \
    --auto-scaling-group-name $ASG_NAME \
    --scheduled-action-name "Shutdown-11PM" \
    --recurrence "0 23 * * *" \
    --desired-capacity 0 \
    --min-size 0 \
    --max-size 6 \
    --profile $PROFILE \
    --region $REGION

echo "创建定时开机操作（早上9点）..."
aws autoscaling put-scheduled-update-group-action \
    --auto-scaling-group-name $ASG_NAME \
    --scheduled-action-name "Startup-9AM" \
    --recurrence "0 9 * * *" \
    --desired-capacity 2 \
    --min-size 2 \
    --max-size 6 \
    --profile $PROFILE \
    --region $REGION

# 配置CPU自动扩缩容策略
echo "配置CPU自动扩缩容策略..."

# 创建目标跟踪扩缩容策略
echo "创建目标跟踪扩缩容策略（CPU 70%）..."
aws autoscaling put-scaling-policy \
    --auto-scaling-group-name $ASG_NAME \
    --policy-name "CPU-TargetTracking-Policy" \
    --policy-type "TargetTrackingScaling" \
    --target-tracking-configuration '{
        "TargetValue": 70.0,
        "PredefinedMetricSpecification": {
            "PredefinedMetricType": "ASGAverageCPUUtilization"
        }
    }' \
    --profile $PROFILE \
    --region $REGION || echo "目标跟踪策略可能已存在"

# 创建简单扩容策略（备用）
echo "创建简单扩容策略..."
SCALE_OUT_POLICY_ARN=$(aws autoscaling put-scaling-policy \
    --auto-scaling-group-name $ASG_NAME \
    --policy-name "CPU-ScaleOut-Simple" \
    --policy-type "SimpleScaling" \
    --adjustment-type "ChangeInCapacity" \
    --scaling-adjustment 1 \
    --cooldown 300 \
    --profile $PROFILE \
    --region $REGION \
    --query 'PolicyARN' --output text 2>/dev/null || echo "")

# 创建简单缩容策略
echo "创建简单缩容策略..."
SCALE_IN_POLICY_ARN=$(aws autoscaling put-scaling-policy \
    --auto-scaling-group-name $ASG_NAME \
    --policy-name "CPU-ScaleIn-Simple" \
    --policy-type "SimpleScaling" \
    --adjustment-type "ChangeInCapacity" \
    --scaling-adjustment -1 \
    --cooldown 300 \
    --profile $PROFILE \
    --region $REGION \
    --query 'PolicyARN' --output text 2>/dev/null || echo "")

# 创建CloudWatch告警
if [ -n "$SCALE_OUT_POLICY_ARN" ] && [ "$SCALE_OUT_POLICY_ARN" != "None" ]; then
    echo "创建CPU高使用率告警..."
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
        --dimensions Name=AutoScalingGroupName,Value=$ASG_NAME \
        --profile $PROFILE \
        --region $REGION || echo "CPU高使用率告警可能已存在"
fi

if [ -n "$SCALE_IN_POLICY_ARN" ] && [ "$SCALE_IN_POLICY_ARN" != "None" ]; then
    echo "创建CPU低使用率告警..."
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
        --dimensions Name=AutoScalingGroupName,Value=$ASG_NAME \
        --profile $PROFILE \
        --region $REGION || echo "CPU低使用率告警可能已存在"
fi

echo "部署完成！"
echo "Auto Scaling Group名称: $ASG_NAME"
echo "启动模板名称: $LAUNCH_TEMPLATE_NAME"
echo "安全组ID: $SECURITY_GROUP_ID"

# 验证部署
echo "验证部署状态..."
aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names $ASG_NAME \
    --profile $PROFILE \
    --region $REGION \
    --query 'AutoScalingGroups[0].{Name:AutoScalingGroupName,DesiredCapacity:DesiredCapacity,MinSize:MinSize,MaxSize:MaxSize}'

echo "定时操作列表:"
aws autoscaling describe-scheduled-actions \
    --auto-scaling-group-name $ASG_NAME \
    --profile $PROFILE \
    --region $REGION \
    --query 'ScheduledUpdateGroupActions[].{Name:ScheduledActionName,Recurrence:Recurrence,DesiredCapacity:DesiredCapacity}'

echo "部署完成！请在AWS Console中查看资源状态。"
echo "使用 ./verify-asg.sh 验证部署状态"
echo "使用 ./cpu-stress-test.sh start 测试CPU自动扩缩容"
