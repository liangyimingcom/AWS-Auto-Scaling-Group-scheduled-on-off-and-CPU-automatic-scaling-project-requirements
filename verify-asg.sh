#!/bin/bash

# ASG状态验证脚本
# 使用方法: ./verify-asg.sh

# 配置变量
PROFILE="china"
REGION="cn-northwest-1"
ASG_NAME="ASG-POC-Group"

echo "=== ASG定时开关机POC状态验证 ==="
echo

# 检查AWS CLI配置
echo "1. 检查AWS CLI配置..."
aws sts get-caller-identity --profile $PROFILE --region $REGION
echo

# 检查Auto Scaling Group状态
echo "2. Auto Scaling Group状态:"
aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names $ASG_NAME \
    --profile $PROFILE \
    --region $REGION \
    --query 'AutoScalingGroups[0].{Name:AutoScalingGroupName,DesiredCapacity:DesiredCapacity,MinSize:MinSize,MaxSize:MaxSize,HealthCheckType:HealthCheckType,CreatedTime:CreatedTime}' \
    --output table
echo

# 检查实例状态
echo "3. 当前实例状态:"
aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names $ASG_NAME \
    --profile $PROFILE \
    --region $REGION \
    --query 'AutoScalingGroups[0].Instances[].{InstanceId:InstanceId,LifecycleState:LifecycleState,HealthStatus:HealthStatus,AvailabilityZone:AvailabilityZone}' \
    --output table
echo

# 检查定时操作
echo "4. 定时操作配置:"
aws autoscaling describe-scheduled-actions \
    --auto-scaling-group-name $ASG_NAME \
    --profile $PROFILE \
    --region $REGION \
    --query 'ScheduledUpdateGroupActions[].{Name:ScheduledActionName,Recurrence:Recurrence,DesiredCapacity:DesiredCapacity,MinSize:MinSize,MaxSize:MaxSize}' \
    --output table
echo

# 检查最近的扩缩容活动
echo "5. 最近的扩缩容活动:"
aws autoscaling describe-scaling-activities \
    --auto-scaling-group-name $ASG_NAME \
    --max-items 5 \
    --profile $PROFILE \
    --region $REGION \
    --query 'Activities[].{ActivityId:ActivityId,Description:Description,Cause:Cause,StartTime:StartTime,StatusCode:StatusCode}' \
    --output table
echo

# 检查扩缩容策略
echo "6. 扩缩容策略配置:"
aws autoscaling describe-policies \
    --auto-scaling-group-name $ASG_NAME \
    --profile $PROFILE \
    --region $REGION \
    --query 'ScalingPolicies[].{Name:PolicyName,Type:PolicyType,AdjustmentType:AdjustmentType,ScalingAdjustment:ScalingAdjustment,Cooldown:Cooldown}' \
    --output table
echo

# 检查CloudWatch告警
echo "7. CloudWatch告警状态:"
aws cloudwatch describe-alarms \
    --alarm-names "ASG-POC-CPU-High" "ASG-POC-CPU-Low" \
    --profile $PROFILE \
    --region $REGION \
    --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Threshold:Threshold,ComparisonOperator:ComparisonOperator,EvaluationPeriods:EvaluationPeriods}' \
    --output table 2>/dev/null || echo "告警可能不存在"
echo

# 检查启动模板
echo "8. 启动模板信息:"
LAUNCH_TEMPLATE_NAME=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names $ASG_NAME \
    --profile $PROFILE \
    --region $REGION \
    --query 'AutoScalingGroups[0].LaunchTemplate.LaunchTemplateName' \
    --output text)

if [ "$LAUNCH_TEMPLATE_NAME" != "None" ]; then
    aws ec2 describe-launch-templates \
        --launch-template-names $LAUNCH_TEMPLATE_NAME \
        --profile $PROFILE \
        --region $REGION \
        --query 'LaunchTemplates[0].{Name:LaunchTemplateName,LatestVersionNumber:LatestVersionNumber,CreatedBy:CreatedBy,CreateTime:CreateTime}' \
        --output table
fi
echo

# 检查当前时间和下次执行时间
echo "9. 时间信息:"
echo "当前UTC时间: $(date -u)"
echo "当前本地时间: $(date)"
echo "注意: 定时操作使用UTC时间"
echo "- 关机时间: 每天23:00 UTC"
echo "- 开机时间: 每天09:00 UTC (开机后最小2台，最大6台)"
echo "- CPU自动扩缩容: 开机时间段内生效"
echo "  * CPU > 70% 时扩容"
echo "  * CPU < 30% 时缩容（但不低于最小2台）"
echo

echo "=== 验证完成 ==="
