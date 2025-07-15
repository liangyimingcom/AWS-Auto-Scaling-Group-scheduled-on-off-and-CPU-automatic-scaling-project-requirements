#!/bin/bash

# ASG资源清理脚本
# 使用方法: ./cleanup-asg.sh

set -e

# 配置变量
PROFILE="china"
REGION="cn-northwest-1"
ASG_NAME="ASG-POC-Group"
LAUNCH_TEMPLATE_NAME="ASG-POC-LaunchTemplate"
SECURITY_GROUP_NAME="ASG-POC-SG"

echo "开始清理ASG POC资源..."

# 删除CloudWatch告警
echo "删除CloudWatch告警..."
aws cloudwatch delete-alarms \
    --alarm-names "ASG-POC-CPU-High" "ASG-POC-CPU-Low" \
    --profile $PROFILE \
    --region $REGION || echo "告警可能不存在"

# 删除扩缩容策略
echo "删除扩缩容策略..."
aws autoscaling delete-policy \
    --auto-scaling-group-name $ASG_NAME \
    --policy-name "CPU-TargetTracking-Policy" \
    --profile $PROFILE \
    --region $REGION || echo "目标跟踪策略可能不存在"

aws autoscaling delete-policy \
    --auto-scaling-group-name $ASG_NAME \
    --policy-name "CPU-ScaleOut-Simple" \
    --profile $PROFILE \
    --region $REGION || echo "扩容策略可能不存在"

aws autoscaling delete-policy \
    --auto-scaling-group-name $ASG_NAME \
    --policy-name "CPU-ScaleIn-Simple" \
    --profile $PROFILE \
    --region $REGION || echo "缩容策略可能不存在"

# 删除定时操作
echo "删除定时操作..."
aws autoscaling delete-scheduled-action \
    --auto-scaling-group-name $ASG_NAME \
    --scheduled-action-name "Shutdown-11PM" \
    --profile $PROFILE \
    --region $REGION || echo "定时关机操作可能不存在"

aws autoscaling delete-scheduled-action \
    --auto-scaling-group-name $ASG_NAME \
    --scheduled-action-name "Startup-9AM" \
    --profile $PROFILE \
    --region $REGION || echo "定时开机操作可能不存在"

# 删除Auto Scaling Group
echo "删除Auto Scaling Group..."
aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name $ASG_NAME \
    --min-size 0 \
    --desired-capacity 0 \
    --profile $PROFILE \
    --region $REGION || echo "ASG可能不存在"

# 等待实例终止
echo "等待实例终止..."
sleep 30

aws autoscaling delete-auto-scaling-group \
    --auto-scaling-group-name $ASG_NAME \
    --force-delete \
    --profile $PROFILE \
    --region $REGION || echo "ASG可能不存在"

# 删除启动模板
echo "删除启动模板..."
aws ec2 delete-launch-template \
    --launch-template-name $LAUNCH_TEMPLATE_NAME \
    --profile $PROFILE \
    --region $REGION || echo "启动模板可能不存在"

# 删除安全组
echo "删除安全组..."
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
    --group-names $SECURITY_GROUP_NAME \
    --profile $PROFILE \
    --region $REGION \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$SECURITY_GROUP_ID" != "None" ] && [ -n "$SECURITY_GROUP_ID" ]; then
    aws ec2 delete-security-group \
        --group-id $SECURITY_GROUP_ID \
        --profile $PROFILE \
        --region $REGION || echo "安全组删除失败，可能仍在使用中"
fi

# 删除IAM资源
echo "删除IAM资源..."
aws iam remove-role-from-instance-profile \
    --instance-profile-name ASG-EC2-InstanceProfile \
    --role-name ASG-EC2-Role \
    --profile $PROFILE \
    --region $REGION || echo "角色可能已移除"

aws iam delete-instance-profile \
    --instance-profile-name ASG-EC2-InstanceProfile \
    --profile $PROFILE \
    --region $REGION || echo "实例配置文件可能不存在"

aws iam detach-role-policy \
    --role-name ASG-EC2-Role \
    --policy-arn arn:aws-cn:iam::aws:policy/AmazonSSMManagedInstanceCore \
    --profile $PROFILE \
    --region $REGION || echo "策略可能已分离"

aws iam delete-role \
    --role-name ASG-EC2-Role \
    --profile $PROFILE \
    --region $REGION || echo "角色可能不存在"

# 清理临时文件
echo "清理临时文件..."
rm -f launch-template-config.json

echo "清理完成！"
echo "请检查AWS Console确认所有资源已删除。"
